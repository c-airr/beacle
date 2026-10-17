package plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	lua "github.com/yuin/gopher-lua"
)

const (
	readMax     = 1 << 20
	execTimeout = 5 * time.Second
	// maxMetrics bounds how many names a wildcard metric can spread over.
	maxMetrics  = 256
	httpTimeout = 10 * time.Second
	// hostMargin is the most a host function leaves of the call it runs in;
	// a short call (a 500 ms slot) keeps a tenth of what is left instead.
	hostMargin = time.Second
)

// OpenSystem adds beacle.read, beacle.list, beacle.write and beacle.exec,
// limited to what the manifest's permissions name. The agent opens these;
// the backend does not.
func (r *Runtime) OpenSystem() {
	r.Set("read", r.luaRead)
	r.Set("list", r.luaList)
	r.Set("write", r.luaWrite)
	r.Set("exec", r.luaExec)
}

// OpenMetrics adds beacle.metric for the metrics the manifest declares.
func (r *Runtime) OpenMetrics() { r.Set("metric", r.luaMetric) }

// OpenHTTP adds beacle.http.get/post/request for the hosts the manifest
// names.
func (r *Runtime) OpenHTTP() {
	r.SetIn("http", "get", r.luaHTTP("GET"))
	r.SetIn("http", "post", r.luaHTTP("POST"))
	r.SetIn("http", "request", r.luaHTTPRequest)
}

// Values is the latest reading of every metric, keyed by MetricKey.
func (r *Runtime) Values() map[string]float64 {
	r.dataMu.Lock()
	defer r.dataMu.Unlock()
	out := make(map[string]float64, len(r.values))
	for k, v := range r.values {
		out[MetricKey(r.Manifest.ID, k)] = v
	}
	return out
}

// allowedPath cleans p and checks it against prefixes. The check is on the
// path as written, not with symlinks resolved: /sys/class/hwmon is nothing
// but symlinks into /sys/devices. beacle.write never creates a link, so a
// plugin can only follow links that already exist.
func allowedPath(p string, prefixes []string) (string, bool) {
	if !filepath.IsAbs(p) {
		return "", false
	}
	p = filepath.Clean(p)
	for _, pre := range prefixes {
		pre = filepath.Clean(pre)
		if p == pre || strings.HasPrefix(p, strings.TrimSuffix(pre, string(filepath.Separator))+string(filepath.Separator)) {
			return p, true
		}
	}
	return "", false
}

func fail(L *lua.LState, err string) int {
	L.Push(lua.LNil)
	L.Push(lua.LString(err))
	return 2
}

func (r *Runtime) luaRead(L *lua.LState) int {
	p, ok := allowedPath(L.CheckString(1), r.Manifest.Permissions.Read)
	if !ok {
		return fail(L, "permission denied: path not in permissions.read")
	}
	f, err := os.Open(p)
	if err != nil {
		return fail(L, err.Error())
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, readMax+1))
	if err != nil {
		return fail(L, err.Error())
	}
	if len(b) > readMax {
		return fail(L, "file larger than 1 MiB")
	}
	L.Push(lua.LString(b))
	return 1
}

func (r *Runtime) luaList(L *lua.LState) int {
	p, ok := allowedPath(L.CheckString(1), r.Manifest.Permissions.Read)
	if !ok {
		return fail(L, "permission denied: path not in permissions.read")
	}
	entries, err := os.ReadDir(p)
	if err != nil {
		return fail(L, err.Error())
	}
	t := L.CreateTable(len(entries), 0)
	for _, e := range entries {
		t.Append(lua.LString(e.Name()))
	}
	L.Push(t)
	return 1
}

// luaWrite: beacle.write(path, data, [{append = true}]) creates or replaces
// a file (0644) under permissions.write. Replacing goes through a temporary
// file, so a reader never sees half of it.
func (r *Runtime) luaWrite(L *lua.LState) int {
	p, ok := allowedPath(L.CheckString(1), r.Manifest.Permissions.Write)
	if !ok {
		return fail(L, "permission denied: path not in permissions.write")
	}
	data := L.CheckString(2)
	if len(data) > readMax {
		return fail(L, "data larger than 1 MiB")
	}
	if st, err := os.Lstat(p); err == nil && st.Mode()&os.ModeSymlink != 0 {
		return fail(L, "refusing to write through a symlink")
	}
	var err error
	if opts, _ := L.Get(3).(*lua.LTable); opts != nil && lua.LVAsBool(opts.RawGetString("append")) {
		var f *os.File
		if f, err = os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, err = f.WriteString(data)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
		}
	} else {
		// A fresh name (O_EXCL): a fixed one could be a link someone planted.
		var f *os.File
		if f, err = os.CreateTemp(filepath.Dir(p), ".beacle-*"); err == nil {
			_, err = f.WriteString(data)
			if cerr := f.Close(); err == nil {
				err = cerr
			}
			if err == nil {
				err = os.Chmod(f.Name(), 0o644)
			}
			if err == nil {
				err = os.Rename(f.Name(), p)
			}
			if err != nil {
				os.Remove(f.Name())
			}
		}
	}
	if err != nil {
		return fail(L, err.Error())
	}
	L.Push(lua.LTrue)
	return 1
}

// cappedBuffer keeps the first n bytes and drops the rest, so a chatty
// program cannot grow the agent's memory.
type cappedBuffer struct {
	bytes.Buffer
	n int
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	if room := c.n - c.Len(); room > 0 {
		c.Buffer.Write(p[:min(room, len(p))])
	}
	return len(p), nil
}

// luaExec: beacle.exec(program, [args], [{stdin, env, dir, timeout}])
// returns stdout, exit code, stderr. timeout is in seconds (default 5), cut to
// what is left of the call.
func (r *Runtime) luaExec(L *lua.LState) int {
	cmd := L.CheckString(1)
	if !slices.Contains(r.Manifest.Permissions.Exec, cmd) {
		return fail(L, "permission denied: "+cmd+" not in permissions.exec")
	}
	var args []string
	if t, ok := L.Get(2).(*lua.LTable); ok {
		for i := 1; i <= t.MaxN(); i++ {
			args = append(args, t.RawGetInt(i).String())
		}
	}
	limit := execTimeout
	opts, _ := L.Get(3).(*lua.LTable)
	if opts != nil {
		if n, ok := opts.RawGetString("timeout").(lua.LNumber); ok && n > 0 {
			limit = time.Duration(float64(n) * float64(time.Second))
		}
	}
	ctx, cancel := hostTimeout(L, limit)
	defer cancel()
	c := exec.CommandContext(ctx, cmd, args...)
	out, errOut := &cappedBuffer{n: readMax}, &cappedBuffer{n: readMax}
	c.Stdout, c.Stderr = out, errOut
	if opts != nil {
		if s, ok := opts.RawGetString("stdin").(lua.LString); ok {
			c.Stdin = strings.NewReader(string(s))
		}
		if d, ok := opts.RawGetString("dir").(lua.LString); ok {
			c.Dir = string(d)
		}
		if env, ok := opts.RawGetString("env").(*lua.LTable); ok {
			c.Env = os.Environ()
			bad := ""
			env.ForEach(func(k, v lua.LValue) {
				name := k.String()
				// These load code into the program: with beacle.write, any
				// program in permissions.exec would run whatever was written.
				if strings.HasPrefix(name, "LD_") || strings.HasPrefix(name, "DYLD_") || name == "" || strings.Contains(name, "=") {
					bad = name
				}
				c.Env = append(c.Env, name+"="+v.String())
			})
			if bad != "" {
				return fail(L, "env "+bad+" is not allowed")
			}
		}
	}
	err := c.Run()
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		return fail(L, "timed out")
	case errors.As(err, &exit):
		L.Push(lua.LString(out.String()))
		L.Push(lua.LNumber(exit.ExitCode()))
		L.Push(lua.LString(errOut.String()))
		return 3
	case err != nil:
		return fail(L, err.Error())
	}
	L.Push(lua.LString(out.String()))
	L.Push(lua.LNumber(0))
	L.Push(lua.LString(errOut.String()))
	return 3
}

// A metric's name as reported: a wildcard one ("disk_*") spreads over names
// a plugin makes up, so they are held to what a key may contain.
var metricNameRe = regexp.MustCompile(`^[a-z0-9_-]{1,64}$`)

// luaMetric: beacle.metric(name, value); a nil value drops the metric (a
// disk that was unplugged), so it stops showing its last reading.
func (r *Runtime) luaMetric(L *lua.LState) int {
	name := L.CheckString(1)
	if _, ok := r.Manifest.MetricDef(name); !ok || !metricNameRe.MatchString(name) {
		L.ArgError(1, fmt.Sprintf("metric %q is not declared in manifest.json", name))
	}
	if L.Get(2) == lua.LNil {
		r.dataMu.Lock()
		delete(r.values, name)
		r.dataMu.Unlock()
		return 0
	}
	v := float64(L.CheckNumber(2))
	r.dataMu.Lock()
	defer r.dataMu.Unlock()
	if _, had := r.values[name]; !had && len(r.values) >= maxMetrics {
		L.RaiseError("more than %d metrics", maxMetrics)
	}
	r.values[name] = v
	return 0
}

// hostAllowed: listed in permissions.http (or "*" there), or the host of a
// url the user typed into the plugin's settings.
func (r *Runtime) hostAllowed(host string) bool {
	perms := r.Manifest.Permissions.HTTP
	if slices.Contains(perms, "*") || slices.Contains(perms, host) {
		return true
	}
	for _, f := range r.Manifest.Config {
		if f.Type != "url" {
			continue
		}
		if s, ok := r.Config[f.Key].(string); ok && s != "" {
			if u, err := url.Parse(s); err == nil && u.Hostname() == host {
				return true
			}
		}
	}
	return false
}

type httpReq struct {
	method, url, body string
	headers           map[string]string
	timeout           time.Duration
}

// doHTTP runs one request and reads at most 1 MiB of the answer.
func (r *Runtime) doHTTP(L *lua.LState, q httpReq) (*http.Response, []byte, error) {
	u, err := url.Parse(q.url)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, nil, errors.New("bad url")
	}
	if !r.hostAllowed(u.Hostname()) {
		return nil, nil, errors.New("permission denied: " + u.Hostname() + " not in permissions.http")
	}
	limit := httpTimeout
	if q.timeout > 0 {
		limit = q.timeout
	}
	ctx, cancel := hostTimeout(L, limit)
	defer cancel()
	var body io.Reader
	if q.body != "" {
		body = strings.NewReader(q.body)
	}
	req, err := http.NewRequestWithContext(ctx, q.method, q.url, body)
	if err != nil {
		return nil, nil, err
	}
	for k, v := range q.headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{CheckRedirect: func(next *http.Request, _ []*http.Request) error {
		// A redirect must not lead outside the hosts the user approved.
		if !r.hostAllowed(next.URL.Hostname()) {
			return errors.New("redirect to " + next.URL.Hostname() + " not in permissions.http")
		}
		return nil
	}}
	resp, err := client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, readMax))
	if err != nil {
		return nil, nil, err
	}
	return resp, b, nil
}

// luaHTTP: beacle.http.get(url) and beacle.http.post(url, body, [type])
// return body, status.
func (r *Runtime) luaHTTP(method string) lua.LGFunction {
	return func(L *lua.LState) int {
		q := httpReq{method: method, url: L.CheckString(1)}
		if method == "POST" {
			q.body = L.OptString(2, "")
			q.headers = map[string]string{"Content-Type": L.OptString(3, "application/json")}
		}
		resp, b, err := r.doHTTP(L, q)
		if err != nil {
			return fail(L, err.Error())
		}
		L.Push(lua.LString(b))
		L.Push(lua.LNumber(resp.StatusCode))
		return 2
	}
}

// luaHTTPRequest: beacle.http.request{method, url, headers, body, timeout}
// returns {status, headers, body}, or nil, err. A table body goes as JSON.
func (r *Runtime) luaHTTPRequest(L *lua.LState) int {
	t := L.CheckTable(1)
	q := httpReq{
		method:  strings.ToUpper(lua.LVAsString(t.RawGetString("method"))),
		url:     lua.LVAsString(t.RawGetString("url")),
		headers: map[string]string{},
	}
	if q.method == "" {
		q.method = "GET"
	}
	if h, ok := t.RawGetString("headers").(*lua.LTable); ok {
		h.ForEach(func(k, v lua.LValue) { q.headers[k.String()] = v.String() })
	}
	switch b := t.RawGetString("body").(type) {
	case lua.LString:
		q.body = string(b)
	case *lua.LTable:
		raw, err := json.Marshal(ToGo(b))
		if err != nil {
			return fail(L, err.Error())
		}
		q.body = string(raw)
		if !hasHeader(q.headers, "Content-Type") {
			q.headers["Content-Type"] = "application/json"
		}
	}
	if n, ok := t.RawGetString("timeout").(lua.LNumber); ok && n > 0 {
		q.timeout = time.Duration(float64(n) * float64(time.Second))
	}
	resp, b, err := r.doHTTP(L, q)
	if err != nil {
		return fail(L, err.Error())
	}
	headers := L.NewTable()
	for k := range resp.Header {
		headers.RawSetString(strings.ToLower(k), lua.LString(resp.Header.Get(k)))
	}
	out := L.NewTable()
	out.RawSetString("status", lua.LNumber(resp.StatusCode))
	out.RawSetString("headers", headers)
	out.RawSetString("body", lua.LString(b))
	L.Push(out)
	return 1
}

func hasHeader(h map[string]string, name string) bool {
	for k := range h {
		if strings.EqualFold(k, name) {
			return true
		}
	}
	return false
}

// hostTimeout bounds a host function by its own limit, cut so it gives up
// a little before the call it runs in. A host that never answered used to
// take the whole call with it: the task failed instead of the plugin getting
// nil, err to handle, and five such tasks in a row stopped the plugin.
func hostTimeout(L *lua.LState, limit time.Duration) (context.Context, context.CancelFunc) {
	ctx := callCtx(L)
	if deadline, ok := ctx.Deadline(); ok {
		left := time.Until(deadline)
		limit = min(limit, max(left-min(hostMargin, left/10), 0))
	}
	return context.WithTimeout(ctx, limit)
}

// callCtx is the deadline of the call this host function runs in.
func callCtx(L *lua.LState) context.Context {
	if ctx := L.Context(); ctx != nil {
		return ctx
	}
	return context.Background()
}
