package plugin

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	lua "github.com/yuin/gopher-lua"
)

const (
	readMax     = 1 << 20
	execTimeout = 5 * time.Second
	httpTimeout = 10 * time.Second
	// hostMargin is the most a host function leaves of the call it runs in;
	// a short call (a 500 ms slot) keeps a tenth of what is left instead.
	hostMargin = time.Second
)

// OpenSystem adds beacle.read, beacle.list and beacle.exec, limited to what
// the manifest's permissions name. The agent opens these; the backend does not.
func (r *Runtime) OpenSystem() {
	r.Set("read", r.luaRead)
	r.Set("list", r.luaList)
	r.Set("exec", r.luaExec)
}

// OpenMetrics adds beacle.metric for the metrics the manifest declares.
func (r *Runtime) OpenMetrics() { r.Set("metric", r.luaMetric) }

// OpenHTTP adds beacle.http.get/post for the hosts the manifest names.
func (r *Runtime) OpenHTTP() {
	r.SetIn("http", "get", r.luaHTTP("GET"))
	r.SetIn("http", "post", r.luaHTTP("POST"))
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

// allowedPath cleans p and checks it against the read prefixes. The check is
// on the path as written, not with symlinks resolved: /sys/class/hwmon is
// nothing but symlinks into /sys/devices. Plugins cannot create files, so
// they can only follow links that already exist.
func (r *Runtime) allowedPath(p string) (string, bool) {
	if !filepath.IsAbs(p) {
		return "", false
	}
	p = filepath.Clean(p)
	for _, pre := range r.Manifest.Permissions.Read {
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
	p, ok := r.allowedPath(L.CheckString(1))
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
	p, ok := r.allowedPath(L.CheckString(1))
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
	ctx, cancel := hostTimeout(L, execTimeout)
	defer cancel()
	c := exec.CommandContext(ctx, cmd, args...)
	out := &cappedBuffer{n: readMax}
	c.Stdout = out
	err := c.Run()
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		return fail(L, "timed out")
	case errors.As(err, &exit):
		L.Push(lua.LString(out.String()))
		L.Push(lua.LNumber(exit.ExitCode()))
		return 2
	case err != nil:
		return fail(L, err.Error())
	}
	L.Push(lua.LString(out.String()))
	L.Push(lua.LNumber(0))
	return 2
}

func (r *Runtime) luaMetric(L *lua.LState) int {
	name := L.CheckString(1)
	v := float64(L.CheckNumber(2))
	if _, ok := r.Manifest.Metrics[name]; !ok {
		L.ArgError(1, fmt.Sprintf("metric %q is not declared in manifest.json", name))
	}
	r.dataMu.Lock()
	r.values[name] = v
	r.dataMu.Unlock()
	return 0
}

func (r *Runtime) luaHTTP(method string) lua.LGFunction {
	return func(L *lua.LState) int {
		raw := L.CheckString(1)
		u, err := url.Parse(raw)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return fail(L, "bad url")
		}
		if !slices.Contains(r.Manifest.Permissions.HTTP, u.Hostname()) {
			return fail(L, "permission denied: "+u.Hostname()+" not in permissions.http")
		}
		ctx, cancel := hostTimeout(L, httpTimeout)
		defer cancel()
		var body io.Reader
		if method == "POST" {
			body = strings.NewReader(L.OptString(2, ""))
		}
		req, err := http.NewRequestWithContext(ctx, method, raw, body)
		if err != nil {
			return fail(L, err.Error())
		}
		if method == "POST" {
			req.Header.Set("Content-Type", L.OptString(3, "application/json"))
		}
		client := &http.Client{CheckRedirect: func(next *http.Request, _ []*http.Request) error {
			// A redirect must not lead outside the hosts the user approved.
			if !slices.Contains(r.Manifest.Permissions.HTTP, next.URL.Hostname()) {
				return errors.New("redirect to " + next.URL.Hostname() + " not in permissions.http")
			}
			return nil
		}}
		resp, err := client.Do(req)
		if err != nil {
			return fail(L, err.Error())
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(io.LimitReader(resp.Body, readMax))
		if err != nil {
			return fail(L, err.Error())
		}
		L.Push(lua.LString(b))
		L.Push(lua.LNumber(resp.StatusCode))
		return 2
	}
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
