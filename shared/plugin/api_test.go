package plugin

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func newTestConfig(t *testing.T, m Manifest, config map[string]any, src string) *Runtime {
	t.Helper()
	if m.ID == "" {
		m.ID = "test"
	}
	r := New(m, "")
	r.Config = ConfigValues(m, config, false)
	r.OpenSystem()
	r.OpenMetrics()
	r.OpenHTTP()
	t.Cleanup(r.Close)
	if err := r.Load(src, "test.lua"); err != nil {
		t.Fatalf("load: %v", err)
	}
	return r
}

func TestClockAndDate(t *testing.T) {
	r := newTest(t, Manifest{}, `
beacle.on("now", function() return beacle.now() end)
beacle.on("date", function() return beacle.date(0, "2006") end)`)
	now := call(t, r, "now", nil).(float64)
	if d := time.Since(time.UnixMilli(int64(now * 1000))); d < 0 || d > 5*time.Second {
		t.Errorf("beacle.now() = %v, off by %s", now, d)
	}
	if y := call(t, r, "date", nil); y != "1970" && y != "1969" { // 0 is 1969 west of Greenwich
		t.Errorf("beacle.date(0) = %v", y)
	}
}

func TestConfigDefaultsAndSecretsStayOffAgents(t *testing.T) {
	m := Manifest{ID: "c", Config: []ConfigField{
		{Key: "url", Type: "url", Default: "http://x"},
		{Key: "token", Type: "secret"},
		{Key: "every", Type: "number", Default: 30.0},
	}}
	stored := map[string]any{"token": "s3cret", "every": 60.0, "gone": "x"}
	got := ConfigValues(m, stored, false)
	if got["url"] != "http://x" || got["token"] != "s3cret" || got["every"] != 60.0 || got["gone"] != nil {
		t.Errorf("backend config: %v", got)
	}
	if agent := ConfigValues(m, stored, true); agent["token"] != nil || agent["every"] != 60.0 {
		t.Errorf("agent config: %v", agent)
	}
	r := newTestConfig(t, m, stored, `beacle.on("get", function(k) return beacle.config(k) end)`)
	if v := call(t, r, "get", "every"); v != 60.0 {
		t.Errorf("beacle.config: %v", v)
	}
}

func TestHTTPRequestHeadersMethodsAndConfiguredHosts(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Seen", r.Method+" "+r.Header.Get("Authorization")+" "+r.Header.Get("Content-Type"))
		w.WriteHeader(201)
		w.Write([]byte("ok"))
	}))
	defer srv.Close()
	src := `
beacle.on("req", function(u)
  local r, err = beacle.http.request{ method = "put", url = u, headers = { Authorization = "Bearer t" }, body = { a = 1 } }
  if not r then return { err = err } end
  return { status = r.status, seen = r.headers["x-seen"], body = r.body }
end)`
	// Not listed: refused.
	r := newTest(t, Manifest{}, src)
	if got := call(t, r, "req", srv.URL).(map[string]any); !strings.Contains(got["err"].(string), "permission denied") {
		t.Fatalf("unlisted host: %v", got)
	}
	// Typed into a url setting by the user: allowed.
	m := Manifest{Config: []ConfigField{{Key: "target", Type: "url"}}}
	r = newTestConfig(t, m, map[string]any{"target": srv.URL + "/status"}, src)
	got := call(t, r, "req", srv.URL).(map[string]any)
	if got["status"] != 201.0 || got["seen"] != "PUT Bearer t application/json" || got["body"] != "ok" {
		t.Fatalf("request: %v", got)
	}
	// "*" is any host.
	r = newTest(t, Manifest{Permissions: Permissions{HTTP: []string{"*"}}}, src)
	if got := call(t, r, "req", srv.URL).(map[string]any); got["status"] != 201.0 {
		t.Fatalf("any host: %v", got)
	}
}

func TestWriteOnlyUnderPermittedPrefixes(t *testing.T) {
	dir := t.TempDir()
	allowed := filepath.Join(dir, "out")
	os.MkdirAll(allowed, 0o755)
	r := newTest(t, Manifest{Permissions: Permissions{Write: []string{allowed}}}, `
beacle.on("w", function(a) local ok, err = beacle.write(a.path, a.data, { append = a.append }); return { ok = ok, err = err } end)`)
	f := filepath.Join(allowed, "state")
	call(t, r, "w", map[string]any{"path": f, "data": "a"})
	call(t, r, "w", map[string]any{"path": f, "data": "b", "append": true})
	if b, _ := os.ReadFile(f); string(b) != "ab" {
		t.Errorf("written: %q", b)
	}
	for _, p := range []string{filepath.Join(dir, "x"), filepath.Join(allowed, "..", "x")} {
		got := call(t, r, "w", map[string]any{"path": p, "data": "x"}).(map[string]any)
		if !strings.Contains(got["err"].(string), "permission denied") {
			t.Errorf("write %s: %v", p, got)
		}
	}
	// Read permission is not write permission.
	r = newTest(t, Manifest{Permissions: Permissions{Read: []string{allowed}}}, `
beacle.on("w", function(p) local ok, err = beacle.write(p, "x"); return err end)`)
	if got := call(t, r, "w", f); !strings.Contains(got.(string), "permission denied") {
		t.Errorf("write with read permission: %v", got)
	}
}

func TestExecStdinAndStderr(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("needs sh")
	}
	r := newTest(t, Manifest{Permissions: Permissions{Exec: []string{"sh"}}}, `
beacle.on("run", function()
  local out, code, err = beacle.exec("sh", { "-c", "cat; echo oops >&2; exit 3" }, { stdin = "hi", env = { X = "1" } })
  return { out = out, code = code, err = err }
end)`)
	got := call(t, r, "run", nil).(map[string]any)
	if got["out"] != "hi" || got["code"] != 3.0 || got["err"] != "oops\n" {
		t.Errorf("exec: %v", got)
	}
}

func TestExecRefusesLoaderVariables(t *testing.T) {
	prog := "true"
	if runtime.GOOS == "windows" {
		prog = "hostname"
	}
	r := newTest(t, Manifest{Permissions: Permissions{Exec: []string{prog}}}, `
beacle.on("run", function(p) local out, err = beacle.exec(p, {}, { env = { LD_PRELOAD = "/tmp/x.so" } }); return err end)`)
	if got, _ := call(t, r, "run", prog).(string); !strings.Contains(got, "not allowed") {
		t.Errorf("LD_PRELOAD passed: %q", got)
	}
}

func TestWildcardMetrics(t *testing.T) {
	r := newTest(t, Manifest{ID: "d", Metrics: map[string]MetricDef{"disk_*": {Unit: "%"}}}, `
beacle.on("set", function(n) beacle.metric(n, 5) end)
beacle.on("drop", function(n) beacle.metric(n, nil) end)`)
	call(t, r, "set", "disk_sda")
	if r.Values()["d.disk_sda"] != 5 {
		t.Fatalf("values: %v", r.Values())
	}
	call(t, r, "drop", "disk_sda")
	if _, ok := r.Values()["d.disk_sda"]; ok {
		t.Error("dropped metric still reported")
	}
	for _, bad := range []string{"cpu", "disk_A.B"} {
		if _, err := r.Handle("set", bad, time.Second); err == nil {
			t.Errorf("metric %q accepted", bad)
		}
	}
	if d, ok := LookupMetric(map[string]MetricDef{"d.disk_*": {Unit: "%"}}, "d.disk_sda"); !ok || d.Unit != "%" {
		t.Error("LookupMetric missed the wildcard")
	}
}

func TestManifestValidatesTheNewFields(t *testing.T) {
	for _, raw := range []string{
		`{"id":"a","name":"A","version":"1","permissions":{"api":["GET /api/vps"]},"timeout":60,"config":[{"key":"k","type":"select","options":["x"]}]}`,
		`{"id":"a","name":"A","version":"1","permissions":{"api":["* /api/vps/*/agent/docker/containers"],"write":["/etc/x"]}}`,
	} {
		if _, err := ParseManifest([]byte(raw)); err != nil {
			t.Errorf("valid manifest refused: %v\n%s", err, raw)
		}
	}
	for _, raw := range []string{
		`{"id":"a","name":"A","version":"1","permissions":{"api":["GET /etc"]}}`,
		`{"id":"a","name":"A","version":"1","permissions":{"api":["GET /api/../x"]}}`,
		`{"id":"a","name":"A","version":"1","permissions":{"write":["relative"]}}`,
		`{"id":"a","name":"A","version":"1","timeout":301}`,
		`{"id":"a","name":"A","version":"1","config":[{"key":"k","type":"color"}]}`,
		`{"id":"a","name":"A","version":"1","config":[{"key":"k"},{"key":"k"}]}`,
		`{"id":"a","name":"A","version":"1","config":[{"key":"k","type":"select"}]}`,
	} {
		if _, err := ParseManifest([]byte(raw)); err == nil {
			t.Errorf("bad manifest accepted: %s", raw)
		}
	}
}
