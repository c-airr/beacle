package plugin

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func newTest(t *testing.T, m Manifest, src string) *Runtime {
	t.Helper()
	if m.ID == "" {
		m.ID = "test"
	}
	r := New(m, "")
	r.OpenSystem()
	r.OpenMetrics()
	r.OpenHTTP()
	t.Cleanup(r.Close)
	if err := r.Load(src, "test.lua"); err != nil {
		t.Fatalf("load: %v", err)
	}
	return r
}

func call(t *testing.T, r *Runtime, name string, args any) any {
	t.Helper()
	v, err := r.Handle(name, args, time.Second)
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return v
}

func TestSandboxHasNoEscapes(t *testing.T) {
	r := newTest(t, Manifest{}, `
beacle.on("check", function()
  return { os = os == nil, io = io == nil, load = load == nil, loadstring = loadstring == nil,
           dofile = dofile == nil, require = require == nil, debug = debug == nil,
           package = package == nil }
end)`)
	for k, v := range call(t, r, "check", nil).(map[string]any) {
		if v != true {
			t.Errorf("%s is reachable from a plugin", k)
		}
	}
}

func TestReadIsLimitedToPermittedPrefixes(t *testing.T) {
	dir := t.TempDir()
	allowed := filepath.Join(dir, "ok")
	os.MkdirAll(allowed, 0o755)
	os.WriteFile(filepath.Join(allowed, "temp"), []byte("42000"), 0o644)
	os.WriteFile(filepath.Join(dir, "secret"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(dir, "ok-sibling"), []byte("x"), 0o644)

	r := newTest(t, Manifest{Permissions: Permissions{Read: []string{allowed}}}, `
beacle.on("read", function(p) local v, err = beacle.read(p); return { v = v, err = err } end)
beacle.on("list", function(p) local v, err = beacle.list(p); return { v = v, err = err } end)`)

	got := call(t, r, "read", filepath.Join(allowed, "temp")).(map[string]any)
	if got["v"] != "42000" {
		t.Fatalf("permitted read: %v", got)
	}
	for _, p := range []string{
		filepath.Join(dir, "secret"),
		filepath.Join(allowed, "..", "secret"),
		filepath.Join(dir, "ok-sibling"), // shares the prefix as a string, not as a directory
		"relative/path",
	} {
		got := call(t, r, "read", p).(map[string]any)
		if got["v"] != nil || !strings.Contains(got["err"].(string), "permission denied") {
			t.Errorf("read %s: want denied, got %v", p, got)
		}
	}
	if got := call(t, r, "list", allowed).(map[string]any); len(got["v"].([]any)) != 1 {
		t.Errorf("list: %v", got)
	}
}

func TestExecOnlyListedPrograms(t *testing.T) {
	prog := "true"
	if runtime.GOOS == "windows" {
		prog = "hostname"
	}
	r := newTest(t, Manifest{Permissions: Permissions{Exec: []string{prog}}}, `
beacle.on("run", function(c) local out, code = beacle.exec(c, {}); return { out = out, code = code } end)`)
	if got := call(t, r, "run", prog).(map[string]any); got["code"] != 0.0 {
		t.Errorf("listed program: %v", got)
	}
	if got := call(t, r, "run", "whoami").(map[string]any); got["out"] != nil {
		t.Errorf("unlisted program ran: %v", got)
	}
}

func TestEndlessLoopIsInterrupted(t *testing.T) {
	r := newTest(t, Manifest{}, `
beacle.on("spin", function() while true do end end)
beacle.on("ok", function() return 1 end)`)
	start := time.Now()
	if _, err := r.Handle("spin", nil, 200*time.Millisecond); err == nil {
		t.Fatal("endless loop returned")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("timeout not enforced")
	}
	if v := call(t, r, "ok", nil); v != 1.0 {
		t.Fatalf("plugin unusable after a timeout: %v", v)
	}
}

func TestMetricMustBeDeclared(t *testing.T) {
	r := newTest(t, Manifest{ID: "temps", Metrics: map[string]MetricDef{"cpu_temp": {Unit: "°C"}}}, `
beacle.on("good", function() beacle.metric("cpu_temp", 54.5) end)
beacle.on("bad", function() beacle.metric("nope", 1) end)`)
	call(t, r, "good", nil)
	if v := r.Values()["temps.cpu_temp"]; v != 54.5 {
		t.Errorf("value: %v", v)
	}
	if _, err := r.Handle("bad", nil, time.Second); err == nil || !strings.Contains(err.Error(), "not declared") {
		t.Errorf("undeclared metric: %v", err)
	}
}

func TestHTTPOnlyListedHosts(t *testing.T) {
	r := newTest(t, Manifest{Permissions: Permissions{HTTP: []string{"example.invalid"}}}, `
beacle.on("get", function(u) local b, err = beacle.http.get(u); return { err = err } end)`)
	got := call(t, r, "get", "http://127.0.0.1:1/").(map[string]any)
	if !strings.Contains(got["err"].(string), "permission denied") {
		t.Errorf("unlisted host: %v", got)
	}
}

func TestEveryRunsAtOnceAndLogsErrors(t *testing.T) {
	r := New(Manifest{ID: "t"}, "")
	t.Cleanup(r.Close)
	src := `local n = 0
beacle.every(5, function() n = n + 1; error("boom " .. n) end)`
	if err := r.Load(src, "t.lua"); err != nil {
		t.Fatal(err)
	}
	// The first run is immediate; the rest would take 20 s of ticks, so only
	// check that the failure was logged and the plugin still runs.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(r.Logs()) == 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if logs := r.Logs(); len(logs) == 0 || !strings.Contains(logs[0], "boom 1") {
		t.Fatalf("logs: %v", logs)
	}
	if r.Err() != "" {
		t.Fatalf("stopped after one failure: %s", r.Err())
	}
}

func TestLoadErrorPutsPluginInError(t *testing.T) {
	r := New(Manifest{ID: "t"}, "")
	if err := r.Load("this is not lua", "t.lua"); err == nil {
		t.Fatal("bad source loaded")
	}
	if r.Err() == "" {
		t.Fatal("no error recorded")
	}
}

func TestStorePersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.json")
	r := New(Manifest{ID: "t"}, path)
	if err := r.Load(`beacle.store.set("k", { a = 1 })`, "t.lua"); err != nil {
		t.Fatal(err)
	}
	r.Close()
	r2 := New(Manifest{ID: "t"}, path)
	defer r2.Close()
	if err := r2.Load(`beacle.on("get", function() return beacle.store.get("k").a end)`, "t.lua"); err != nil {
		t.Fatal(err)
	}
	if v := call(t, r2, "get", nil); v != 1.0 {
		t.Fatalf("store after restart: %v", v)
	}
}

func TestManifestValidation(t *testing.T) {
	good := `{"id":"temps","name":"T","version":"1.0.0","permissions":{"read":["/sys/class/thermal"],"exec":["nvidia-smi"]},"metrics":{"cpu_temp":{"warn":80,"crit":90}}}`
	if _, err := ParseManifest([]byte(good)); err != nil {
		t.Fatalf("good manifest: %v", err)
	}
	for _, bad := range []string{
		`{"id":"Temps!","name":"T","version":"1"}`,
		`{"id":"t","version":"1"}`,
		`{"id":"t","name":"T","version":"1","permissions":{"read":["sys"]}}`,
		`{"id":"t","name":"T","version":"1","permissions":{"exec":["rm -rf"]}}`,
		`{"id":"t","name":"T","version":"1","permissions":{"http":["https://x.com"]}}`,
		`{"id":"t","name":"T","version":"1","metrics":{"Bad Name":{}}}`,
		`{"id":"t","name":"T","version":"1","metrics":{"m":{"warn":90,"crit":80}}}`,
	} {
		if _, err := ParseManifest([]byte(bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}
