package main

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"beacle/shared"
	"beacle/shared/plugin"
)

func TestAPIPermissionPatterns(t *testing.T) {
	perms := []string{"GET /api/vps", "GET /api/vps/*", "* /api/vps/*/agent/docker/containers/*/*", "POST /api/plugins/x/action"}
	for _, c := range []struct {
		method, path string
		ok           bool
	}{
		{"GET", "/api/vps", true},
		{"GET", "/api/vps/abc", true},
		{"POST", "/api/vps/abc", false},        // method not granted
		{"GET", "/api/vps/abc/history", false}, // * is one segment
		{"POST", "/api/vps/a/agent/docker/containers/c1/restart", true},
		{"GET", "/api/vps/a/../alerts", false},     // not clean
		{"GET", "/api/vps//abc", false},            // not clean
		{"GET", "/api/vps/%2e%2e", false},          // escaped
		{"POST", "/api/plugins/x/action", false},   // never, whatever the manifest says
		{"GET", "/api/vps/a/agent/plugins", false}, // nor an agent's plugins
		{"GET", "/api/vps/a/terminal", false},
	} {
		if got := apiAllowed(perms, c.method, c.path); got != c.ok {
			t.Errorf("%s %s: allowed=%v, want %v", c.method, c.path, got, c.ok)
		}
	}
}

func TestBackendPartCallsThePanelAPI(t *testing.T) {
	p, _ := newTestPlugins(t)
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/vps", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, []map[string]string{{"id": "a", "q": r.URL.Query().Get("x")}})
	})
	mux.HandleFunc("POST /api/alerts/{id}/resolve", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		writeJSON(w, http.StatusOK, map[string]any{"id": r.PathValue("id"), "body": body})
	})
	p.api = mux
	manifest := `{"id":"api","name":"API","version":"1","permissions":{"api":["GET /api/vps","POST /api/alerts/*/resolve"]}}`
	src := `
beacle.on("list", function() local v, code = beacle.api("GET", "/api/vps?x=1"); return { id = v[1].id, q = v[1].q, code = code } end)
beacle.on("post", function() local v = beacle.api("POST", "/api/alerts/7/resolve", { why = "fixed" }); return v.body.why end)
beacle.on("denied", function() local v, err = beacle.api("DELETE", "/api/vps"); return err end)`
	if _, err := p.Install(writePkgDir(t, map[string]string{"manifest.json": manifest, "backend.lua": src})); err != nil {
		t.Fatal(err)
	}
	got, err := p.Action("api", "list", nil)
	if m, _ := got.(map[string]any); err != nil || m["id"] != "a" || m["q"] != "1" || m["code"] != 200.0 {
		t.Fatalf("GET: %v %v", got, err)
	}
	if got, _ := p.Action("api", "post", nil); got != "fixed" {
		t.Fatalf("POST with a table body: %v", got)
	}
	if got, _ := p.Action("api", "denied", nil); got == nil {
		t.Fatal("a route outside permissions.api was called")
	}
}

func TestBackendPartRaisesAlertsAndHearsThem(t *testing.T) {
	p, store := newTestPlugins(t)
	p.alerts = NewAlertEngine(store, p.hub)
	p.alerts.SetEvents(p.EmitAlert)
	manifest := `{"id":"up","name":"Up","version":"1"}`
	src := `
beacle.on("down", function() beacle.alert{ key = "site", message = "example.com is down", severity = "critical" } end)
beacle.on("up", function() beacle.resolve("site") end)
beacle.on("event:alert", function(a) beacle.store.set("last", a.message .. (a.resolved and " (resolved)" or "")) end)
beacle.on("last", function() return beacle.store.get("last") end)`
	if _, err := p.Install(writePkgDir(t, map[string]string{"manifest.json": manifest, "backend.lua": src})); err != nil {
		t.Fatal(err)
	}
	open := func() []shared.Alert {
		var out []shared.Alert
		for _, a := range store.ListAlerts() {
			if a.Type == shared.AlertPlugin && !a.Resolved {
				out = append(out, a)
			}
		}
		return out
	}
	waitFor := func(want string) {
		t.Helper()
		for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			if got, _ := p.Action("up", "last", nil); got == want {
				return
			}
		}
		got, _ := p.Action("up", "last", nil)
		t.Fatalf("event:alert: got %v, want %q", got, want)
	}
	p.Action("up", "down", nil)
	p.Action("up", "down", nil) // still open: not a second alert
	if a := open(); len(a) != 1 || a[0].VPSID != localID || a[0].Severity != shared.SeverityCritical {
		t.Fatalf("raised: %+v", a)
	}
	waitFor("example.com is down")
	p.Action("up", "up", nil)
	if a := open(); len(a) != 0 {
		t.Fatalf("not resolved: %+v", a)
	}
	waitFor("example.com is down (resolved)")

	// Removing the plugin closes what it left open.
	p.Action("up", "down", nil)
	if err := p.Remove("up"); err != nil {
		t.Fatal(err)
	}
	if a := open(); len(a) != 0 {
		t.Fatalf("left open after removal: %+v", a)
	}
}

func TestSettingsSecretsAndRestart(t *testing.T) {
	p, _ := newTestPlugins(t)
	manifest := `{"id":"cfg","name":"Cfg","version":"1","config":[
 {"key":"url","type":"url"},{"key":"token","type":"secret"},{"key":"mode","type":"select","options":["a","b"],"default":"a"}]}`
	src := `beacle.on("get", function() return beacle.config() end)`
	if _, err := p.Install(writePkgDir(t, map[string]string{"manifest.json": manifest, "backend.lua": src, "agent.lua": "--"})); err != nil {
		t.Fatal(err)
	}
	if err := p.SetState("cfg", nil, nil, map[string]any{"url": "ftp://x"}); err == nil {
		t.Error("a url that is not http accepted")
	}
	if err := p.SetState("cfg", nil, nil, map[string]any{"mode": "c"}); err == nil {
		t.Error("a select value outside its options accepted")
	}
	if err := p.SetState("cfg", nil, nil, map[string]any{"url": "http://pico/status", "token": "s3cret", "mode": "b"}); err != nil {
		t.Fatal(err)
	}
	got, _ := p.Action("cfg", "get", nil)
	if m, _ := got.(map[string]any); m["token"] != "s3cret" || m["mode"] != "b" {
		t.Fatalf("after save, the plugin sees %v", got)
	}
	// The form never gets the secret back, and saving without it keeps it.
	view := p.List()["plugins"].([]pluginView)[0]
	if view.Values["token"] != true {
		t.Fatalf("secret shown to the panel: %v", view.Values)
	}
	if err := p.SetState("cfg", nil, nil, map[string]any{"url": "http://pico/status", "mode": "a"}); err != nil {
		t.Fatal(err)
	}
	got, _ = p.Action("cfg", "get", nil)
	if m, _ := got.(map[string]any); m["token"] != "s3cret" || m["mode"] != "a" {
		t.Fatalf("secret lost on a save without it: %v", got)
	}
}

func TestVersionBefore(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{
		{"2.2.0", "2.2.5", true},
		{"v2.2.5", "2.2.5", false},
		{"2.3", "2.2.5", false},
		{"2.2", "2.2.5", true},
		{"dev", "2.2.5", false},
		{"", "2.2.5", false},
	} {
		if got := versionBefore(c.a, c.b); got != c.want {
			t.Errorf("versionBefore(%q, %q) = %v", c.a, c.b, got)
		}
	}
}

// The shipped examples are what people copy: they load, take their
// settings, and draw every slot without an error.
func TestShippedExamplesRender(t *testing.T) {
	p, store := newTestPlugins(t)
	e := store.CreateVPS("panther", "panther", "100.1.1.1")
	for _, id := range []string{"temp", "uptime", "neofetch"} {
		if _, err := p.Install(filepath.Join("..", "plugins", "demo", id)); err != nil {
			t.Fatalf("%s: %v", id, err)
		}
	}
	if err := p.SetState("temp", nil, nil, map[string]any{"device": "http://127.0.0.1:1/status", "per_row": "2"}); err != nil {
		t.Fatal(err)
	}
	// Nothing listens there: the test needs no network, and a page that is
	// down is drawn too.
	if err := p.SetState("uptime", nil, nil, map[string]any{"sites": "http://127.0.0.1:1/ http://127.0.0.1:2/"}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond) // first checks run at once
	for _, slot := range []string{"nav.tab", "overview.card", "settings.section", "server.section", "servers.column"} {
		for _, r := range p.Render(slot, e.VPS.ID, "") {
			if r.Error != "" {
				t.Errorf("%s %s: %s", r.Plugin, slot, r.Error)
			}
		}
	}
	for _, id := range []string{"temp", "uptime"} {
		if rt, _ := p.runtime(id); rt == nil || rt.Err() != "" {
			t.Errorf("%s stopped: %v", id, rt)
		}
	}
}

func TestReviewSaysWhatAPluginCanDo(t *testing.T) {
	kinds := func(n []permNote) map[string]string {
		out := map[string]string{}
		for _, x := range n {
			out[x.Kind] = x.Level
		}
		return out
	}
	quiet := kinds(reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{Read: []string{"/sys/class/thermal"}}}, true, false))
	if quiet["read"] != "info" || quiet["agent"] != "info" || len(quiet) != 2 {
		t.Errorf("harmless plugin: %v", quiet)
	}
	if got := kinds(reviewPermissions(plugin.Manifest{}, false, true)); got["none"] != "ok" {
		t.Errorf("no permissions: %v", got)
	}
	risky := kinds(reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{
		HTTP: []string{"*"}, Exec: []string{"/bin/bash", "df"}, Read: []string{"/opt/beacle-agent", "/"},
		Write: []string{"/tmp/x"}, API: []string{"GET /api/vps", "POST /api/vps/*/agent/system/reboot"},
	}}, true, true))
	for kind, level := range map[string]string{
		"http_any": "danger", "exec_shell": "danger", "exec": "warn", "read_sensitive": "danger",
		"write": "danger", "api_write": "danger", "api_read": "warn",
	} {
		if risky[kind] != level {
			t.Errorf("%s: %q, want %q (%v)", kind, risky[kind], level, risky)
		}
	}
	if _, ok := risky["none"]; ok {
		t.Error("a risky plugin is said to touch nothing")
	}
	// Run something on servers + send it to the LAN: red, though each alone is not.
	share := kinds(reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{Exec: []string{"neofetch"}, HTTP: []string{"192.168.1.50"}}}, true, true))
	if share["exfil"] != "danger" {
		t.Errorf("exec + http out not flagged: %v", share)
	}
	// Reading sensors and talking to the server itself stays calm.
	local := kinds(reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{Read: []string{"/sys/class/hwmon"}, HTTP: []string{"127.0.0.1"}}}, true, true))
	if _, ok := local["exfil"]; ok {
		t.Errorf("loopback counted as leaving: %v", local)
	}
}

// These run whatever their arguments say — a pager, a hook, a container with
// the host's disk, a unit, a cron line — so the install dialog must call
// them "any command", not "runs a program". Versioned interpreters too.
func TestReviewKnowsProgramsThatRunAnything(t *testing.T) {
	for _, prog := range []string{
		"git", "/usr/bin/tar", "docker", "podman", "systemd-run", "nsenter", "chroot", "sed",
		"crontab", "timeout", "nice", "setsid", "nohup", "strace", "rsync", "vim", "make",
		"python3.11", "/usr/bin/perl5.36", "php8.2", "lua5.4", "nodejs",
	} {
		got := reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{Exec: []string{prog}}}, true, false)
		if !slices.ContainsFunc(got, func(n permNote) bool { return n.Kind == "exec_shell" }) {
			t.Errorf("%s reviewed as %v, want exec_shell", prog, got)
		}
	}
	for _, prog := range []string{"df", "sensors", "neofetch", "uptime", "nvidia-smi"} {
		got := reviewPermissions(plugin.Manifest{Permissions: plugin.Permissions{Exec: []string{prog}}}, true, false)
		if slices.ContainsFunc(got, func(n permNote) bool { return n.Kind == "exec_shell" }) {
			t.Errorf("%s called any command", prog)
		}
	}
}
