package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path"
	"slices"
	"strconv"
	"strings"
	"time"

	"beacle/shared"
	"beacle/shared/plugin"

	lua "github.com/yuin/gopher-lua"
)

// What backend.lua gets beyond the shared runtime: the panel's own API,
// alerts, metrics of this computer and events. Wired in startBackend.

// localID is the "server" a backend part's metrics and alerts belong to:
// this computer, which runs the panel.
const localID = "local"

func localVPS() shared.VPS { return shared.VPS{ID: localID, Name: "This computer"} }

// pluginAgentMin is the first agent with everything agent.lua may call
// (beacle.write, exec options, settings). An older one is updated when a
// plugin is pushed to it.
const pluginAgentMin = "2.2.5"

// apiBlocked are panel routes no plugin reaches, whatever its manifest says:
// plugins installing plugins (or pushing bundles to agents behind the
// user's back), stopping the panel, and the interactive terminals.
func apiBlocked(p string) bool {
	return strings.Contains(p, "/plugins") || p == "/api/shutdown" ||
		strings.HasSuffix(p, "/terminal") || strings.HasSuffix(p, "/ws")
}

// apiAllowed checks "METHOD /path" against permissions.api. The path must be
// in its clean form, so a pattern cannot be walked out of with "..", "//",
// an escaped character or a "#" that the request drops.
func apiAllowed(perms []string, method, p string) bool {
	if !strings.HasPrefix(p, "/api/") || path.Clean(p) != p || strings.ContainsAny(p, `%\#`) || apiBlocked(p) {
		return false
	}
	for _, a := range perms {
		m, pat, _ := strings.Cut(a, " ")
		if m != "*" && m != method {
			continue
		}
		if ok, _ := path.Match(pat, p); ok {
			return true
		}
	}
	return false
}

// luaAPI: beacle.api(method, path, [body]) calls the panel's API in process,
// as the app does. Returns the decoded answer and the HTTP status, or nil
// and an error when the call is not permitted or did not finish.
func (p *Plugins) luaAPI(m plugin.Manifest) lua.LGFunction {
	return func(L *lua.LState) int {
		method, target := strings.ToUpper(L.CheckString(1)), L.CheckString(2)
		pathOnly, _, _ := strings.Cut(target, "?")
		if !apiAllowed(m.Permissions.API, method, pathOnly) {
			return luaFail(L, "permission denied: "+method+" "+pathOnly+" not in permissions.api")
		}
		if p.api == nil {
			return luaFail(L, "the panel is still starting")
		}
		var body io.Reader
		switch b := L.Get(3).(type) {
		case lua.LString:
			body = strings.NewReader(string(b))
		case *lua.LTable:
			raw, err := json.Marshal(plugin.ToGo(b))
			if err != nil {
				return luaFail(L, err.Error())
			}
			body = strings.NewReader(string(raw))
		}
		ctx := L.Context()
		if ctx == nil {
			ctx = context.Background()
		}
		req, err := http.NewRequestWithContext(ctx, method, target, body)
		if err != nil {
			return luaFail(L, err.Error())
		}
		req.RemoteAddr = "127.0.0.1:0" // as the app, on the loopback API
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		done := make(chan struct{})
		go func() {
			defer close(done)
			p.api.ServeHTTP(rec, req)
		}()
		select {
		case <-done:
		case <-ctx.Done():
			// The handler may still finish; its answer goes nowhere.
			return luaFail(L, "timed out")
		}
		var out any
		if json.Unmarshal(rec.Body.Bytes(), &out) != nil {
			out = rec.Body.String()
		}
		L.Push(plugin.FromGo(L, out))
		L.Push(lua.LNumber(rec.Code))
		return 2
	}
}

func luaFail(L *lua.LState, msg string) int {
	L.Push(lua.LNil)
	L.Push(lua.LString(msg))
	return 2
}

// alertTarget is the server an alert is about: the one named, else this
// computer.
func (p *Plugins) alertTarget(L *lua.LState, server string) shared.VPS {
	if server == "" || server == localID {
		return localVPS()
	}
	e := p.store.GetVPS(server)
	if e == nil {
		L.ArgError(1, "no server "+server)
	}
	return e.VPS
}

// luaAlert: beacle.alert{key, message, severity = "warning"|"critical",
// server} raises an alert like the panel's own: in the list, on the
// Overview and through the webhooks. Raising the same key again while it is
// open does nothing; beacle.resolve(key, [server]) closes it.
func (p *Plugins) luaAlert(id string) lua.LGFunction {
	return func(L *lua.LState) int {
		t := L.CheckTable(1)
		key := lua.LVAsString(t.RawGetString("key"))
		msg := lua.LVAsString(t.RawGetString("message"))
		if key == "" || msg == "" {
			L.ArgError(1, "key and message are required")
		}
		sev := shared.SeverityWarning
		if lua.LVAsString(t.RawGetString("severity")) == "critical" {
			sev = shared.SeverityCritical
		}
		vps := p.alertTarget(L, lua.LVAsString(t.RawGetString("server")))
		if p.alerts != nil {
			p.alerts.RaisePlugin(vps, sev, id+"|"+key, msg)
		}
		return 0
	}
}

func (p *Plugins) luaResolve(id string) lua.LGFunction {
	return func(L *lua.LState) int {
		key := L.CheckString(1)
		vps := p.alertTarget(L, L.OptString(2, ""))
		if p.alerts != nil {
			p.alerts.ResolvePlugin(vps.ID, id+"|"+key)
		}
		return 0
	}
}

// RecordLocal takes the backend parts' metrics once a minute: into history
// (charts with server = "local") and through the alert levels the manifests
// declare, like an agent's.
func (p *Plugins) RecordLocal() {
	for range time.Tick(historyInterval) {
		values := p.localValues()
		if len(values) == 0 {
			continue
		}
		if p.history != nil {
			p.history.Record(localID, shared.MetricSample{At: time.Now().UTC(), Plugins: values})
		}
		if p.alerts != nil {
			p.alerts.EvaluateLocal(values, p.MetricDefs())
		}
	}
}

func (p *Plugins) localValues() map[string]float64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	values := map[string]float64{}
	for _, bp := range p.list {
		if bp.rt != nil && bp.state.Enabled {
			for k, v := range bp.rt.Values() {
				values[k] = v
			}
		}
	}
	return values
}

// Emit hands an event to every backend part with a beacle.on("event:<name>")
// handler. Each runs on its own goroutine: the caller may hold locks a
// handler's beacle.alert would need.
func (p *Plugins) Emit(name string, payload any) {
	p.mu.Lock()
	var rts []*plugin.Runtime
	for _, bp := range p.list {
		if bp.rt != nil && bp.state.Enabled {
			rts = append(rts, bp.rt)
		}
	}
	p.mu.Unlock()
	for _, rt := range rts {
		go func() {
			// Asked here, not above: it waits for a call in progress.
			if !rt.HasHandler("event:" + name) {
				return
			}
			if _, err := rt.Handle("event:"+name, payload, rt.Manifest.CallTimeout()); err != nil {
				rt.Logf("event %s: %v", name, err)
			}
		}()
	}
}

// EmitAlert is "event:alert": an alert raised or resolved.
func (p *Plugins) EmitAlert(a shared.Alert) {
	p.Emit("alert", map[string]any{
		"id": a.ID, "type": string(a.Type), "severity": string(a.Severity), "message": a.Message,
		"key": a.Key, "server": a.VPSID, "server_name": a.VPSName, "resolved": a.Resolved,
	})
}

// maybeUpdateAgent updates a server's agent that is too old for plugins,
// once an hour at most, and only when GitHub has a new enough one.
func (p *Plugins) maybeUpdateAgent(vpsID string) {
	e := p.store.GetVPS(vpsID)
	if e == nil || !versionBefore(e.VPS.AgentVer, pluginAgentMin) {
		return
	}
	p.mu.Lock()
	if time.Since(p.updateTried[vpsID]) < time.Hour {
		p.mu.Unlock()
		return
	}
	p.updateTried[vpsID] = time.Now()
	p.mu.Unlock()
	rel := githubAgentRelease(e.VPS.Arch)
	if rel.tag == "" || versionBefore(rel.tag, pluginAgentMin) {
		return // nothing newer to update to yet
	}
	resp, code, err := p.agentHub.Request(vpsID, http.MethodPost, "/api/update", []byte("{}"), 3*time.Minute)
	if err == nil && code != http.StatusOK {
		err = fmt.Errorf("HTTP %d: %s", code, resp)
	}
	if err != nil {
		log.Printf("plugins: updating the agent on %s (%s) for plugins: %v", e.VPS.Name, e.VPS.AgentVer, err)
		return
	}
	log.Printf("plugins: agent on %s was %s, too old for plugins; updating to %s", e.VPS.Name, e.VPS.AgentVer, rel.tag)
}

// versionBefore compares dotted versions ("v2.2.5", "2.2"). Something that
// is not a version (a dev build) is never before anything.
func versionBefore(a, b string) bool {
	pa, okA := versionParts(a)
	pb, okB := versionParts(b)
	if !okA || !okB {
		return false
	}
	for i := range max(len(pa), len(pb)) {
		x, y := 0, 0
		if i < len(pa) {
			x = pa[i]
		}
		if i < len(pb) {
			y = pb[i]
		}
		if x != y {
			return x < y
		}
	}
	return false
}

func versionParts(v string) ([]int, bool) {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if v == "" {
		return nil, false
	}
	var out []int
	for _, s := range strings.Split(v, ".") {
		n, err := strconv.Atoi(s)
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// cleanConfig checks what the settings form sent against the manifest and
// keeps a secret that was left out (the form never sees it).
func cleanConfig(m plugin.Manifest, old, in map[string]any) (map[string]any, error) {
	out := map[string]any{}
	for _, f := range m.Config {
		v, sent := in[f.Key]
		if !sent || v == nil {
			if f.Type == "secret" && old[f.Key] != nil {
				out[f.Key] = old[f.Key]
			}
			continue
		}
		switch f.Type {
		case "number":
			n, ok := v.(float64)
			if !ok {
				return nil, fmt.Errorf("%s must be a number", f.Key)
			}
			out[f.Key] = n
		case "bool":
			b, ok := v.(bool)
			if !ok {
				return nil, fmt.Errorf("%s must be true or false", f.Key)
			}
			out[f.Key] = b
		default:
			s, ok := v.(string)
			if !ok {
				return nil, fmt.Errorf("%s must be text", f.Key)
			}
			if f.Type == "select" && s != "" && !slices.Contains(f.Options, s) {
				return nil, fmt.Errorf("%s must be one of %s", f.Key, strings.Join(f.Options, ", "))
			}
			if f.Type == "url" && s != "" {
				if !strings.HasPrefix(s, "http://") && !strings.HasPrefix(s, "https://") {
					return nil, errors.New(f.Key + " must start with http:// or https://")
				}
			}
			if s != "" || f.Type == "secret" {
				out[f.Key] = s
			}
		}
	}
	return out, nil
}
