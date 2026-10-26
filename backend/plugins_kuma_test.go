package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"beacle/shared/plugin"
)

// fakeKuma serves /metrics behind an API key and one public status page.
type fakeKuma struct {
	mu     sync.Mutex
	status map[string]int // monitor -> 0 down, 1 up, 2 pending, 3 maintenance
}

func newFakeKuma(t *testing.T) (*fakeKuma, *httptest.Server) {
	k := &fakeKuma{status: map[string]int{"Web": 1, "DB": 0, `Say "hi"`: 1}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		k.mu.Lock()
		defer k.mu.Unlock()
		switch r.URL.Path {
		case "/metrics":
			if _, pass, ok := r.BasicAuth(); !ok || pass != "key" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			var b strings.Builder
			b.WriteString("# HELP monitor_status Monitor Status (1 = UP, 0= DOWN, 2= PENDING, 3= MAINTENANCE)\n# TYPE monitor_status gauge\n")
			for name, st := range k.status {
				esc := strings.ReplaceAll(name, `"`, `\"`)
				b.WriteString(`monitor_status{monitor_name="` + esc + `",monitor_type="http",monitor_url="https://x",monitor_hostname="null",monitor_port="null"} `)
				b.WriteString(string(rune('0'+st)) + "\n")
				b.WriteString(`monitor_response_time{monitor_name="` + esc + `",monitor_type="http"} 42` + "\n")
			}
			_, _ = w.Write([]byte(b.String()))
		case "/api/status-page/home":
			_, _ = w.Write([]byte(`{"publicGroupList":[{"name":"Services","monitorList":[{"id":1,"name":"Web"},{"id":2,"name":"DB"}]}]}`))
		case "/api/status-page/heartbeat/home":
			_, _ = w.Write([]byte(`{"heartbeatList":{"1":[{"status":0,"ping":10},{"status":1,"ping":31}],"2":[{"status":0,"msg":"timeout"}]}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return k, srv
}

func installKuma(t *testing.T) (*Plugins, *Store) {
	t.Helper()
	p, store := newTestPlugins(t)
	p.alerts = NewAlertEngine(store, p.hub)
	if _, err := p.Install(filepath.Join("..", "plugins", "uptime-kuma")); err != nil {
		t.Fatal(err)
	}
	return p, store
}

func renderText(t *testing.T, p *Plugins, slot, tab string) string {
	t.Helper()
	var texts []string
	for _, r := range p.Render(slot, "", tab) {
		if r.Error != "" {
			t.Fatalf("%s: %s", slot, r.Error)
		}
		texts = append(texts, pluginTexts(r.Blocks)...)
	}
	return strings.Join(texts, "\n")
}

// blocksOf returns a slot's blocks as plain JSON values.
func blocksOf(t *testing.T, p *Plugins, slot, tab string) []any {
	t.Helper()
	var out []any
	for _, r := range p.Render(slot, "", tab) {
		if r.Error != "" {
			t.Fatalf("%s: %s", slot, r.Error)
		}
		raw, _ := json.Marshal(r.Blocks)
		var b []any
		_ = json.Unmarshal(raw, &b)
		out = append(out, b...)
	}
	return out
}

func findBlock(blocks any, typ string) map[string]any {
	switch x := blocks.(type) {
	case map[string]any:
		if x["type"] == typ {
			return x
		}
		for _, c := range x {
			if b := findBlock(c, typ); b != nil {
				return b
			}
		}
	case []any:
		for _, c := range x {
			if b := findBlock(c, typ); b != nil {
				return b
			}
		}
	}
	return nil
}

// The setup screen end to end, as the app drives it: type the address and
// key, connect, pick a monitor. The down monitor alerts while it is watched
// and is resolved once it is not.
func TestKumaSetupScreen(t *testing.T) {
	_, kuma := newFakeKuma(t)
	p, store := installKuma(t)

	if !strings.Contains(renderText(t, p, "nav.tab", "kuma"), "Not set up yet") {
		t.Fatal("a fresh install should say it is not set up")
	}
	if list := p.List()["plugins"].([]pluginView); len(list) != 1 || !list[0].Setup {
		t.Fatalf("the plugin list should offer its setup screen: %+v", list)
	}
	if findBlock(blocksOf(t, p, setupSlot, "kuma"), "input") == nil {
		t.Fatal("the setup screen has no input")
	}
	for _, a := range []map[string]any{{"key": "url", "value": kuma.URL + "/"}, {"key": "api_key", "value": "key"}} {
		if _, err := p.Action("kuma", "set", a); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := p.Action("kuma", "connect", nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the monitors on the setup screen", func() bool {
		return findBlock(blocksOf(t, p, setupSlot, "kuma"), "checklist") != nil
	})
	check := findBlock(blocksOf(t, p, setupSlot, "kuma"), "checklist")
	if opts, _ := check["options"].([]any); len(opts) != 3 {
		t.Fatalf("checklist options %v, want the three monitors", check["options"])
	}
	if p.list["kuma"].state.Config["api_key"] != "key" {
		t.Fatal("the key typed on the setup screen was not saved")
	}
	waitFor(t, "DB's alert", func() bool { return openAlerts(store) == 1 })
	tab := renderText(t, p, "nav.tab", "kuma")
	for _, want := range []string{"Web", "DB", `Say "hi"`, "2 up, 1 down"} {
		if !strings.Contains(tab, want) {
			t.Errorf("tab lacks %q:\n%s", want, tab)
		}
	}

	if _, err := p.Action("kuma", "pick", map[string]any{"values": []any{"Web"}}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "DB, no longer watched, to be resolved", func() bool { return openAlerts(store) == 0 })
	waitFor(t, "the tab to show only Web", func() bool {
		tab := renderText(t, p, "nav.tab", "kuma")
		return strings.Contains(tab, "1 up, 0 down") && !strings.Contains(tab, "DB")
	})
}

func TestKumaRefusedKeySaysSo(t *testing.T) {
	_, kuma := newFakeKuma(t)
	p, _ := installKuma(t)
	if err := p.SetState("kuma", nil, nil, map[string]any{"url": kuma.URL, "api_key": "wrong"}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the refusal on the setup screen", func() bool {
		return strings.Contains(renderText(t, p, setupSlot, "kuma"), "API key was refused")
	})
}

func TestKumaStatusPage(t *testing.T) {
	_, kuma := newFakeKuma(t)
	p, store := installKuma(t)
	if err := p.SetState("kuma", nil, nil, map[string]any{"url": kuma.URL, "source": "status page", "slug": "home"}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the status page read", func() bool {
		return strings.Contains(renderText(t, p, "nav.tab", "kuma"), "1 up, 1 down")
	})
	waitFor(t, "DB's alert", func() bool { return openAlerts(store) == 1 })
	if !strings.Contains(renderText(t, p, "overview.card", ""), "timeout") {
		t.Error("the Overview card should say why DB is down")
	}
}

// serveRepo serves this repository's plugins/ as GitHub's raw host would at
// ref "abc123", and at main.
func serveRepo(t *testing.T) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ref, rest, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
		if (ref != "abc123" && ref != "main") || !strings.HasPrefix(rest, "plugins/") || strings.Contains(rest, "..") {
			http.NotFound(w, r)
			return
		}
		b, err := os.ReadFile(filepath.Join("..", filepath.FromSlash(rest)))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(b)
	}))
	t.Cleanup(srv.Close)
	was := catalogBase
	catalogBase = srv.URL
	t.Cleanup(func() { catalogBase = was })
}

func TestCatalogListsAndInstalls(t *testing.T) {
	serveRepo(t)
	p, _ := newTestPlugins(t)
	if _, err := p.Install(filepath.Join("..", "plugins", "demo", "temp")); err != nil {
		t.Fatal(err)
	}
	p.list["temp"].manifest.Version = "1.0.0" // an older install

	out, err := p.Catalog("abc123", "2.2.6")
	if err != nil {
		t.Fatal(err)
	}
	if out["ref"] != "abc123" {
		t.Errorf("ref %v, want the app's own", out["ref"])
	}
	byID := map[string]map[string]any{}
	for _, e := range out["plugins"].([]map[string]any) {
		byID[e["id"].(string)] = e
	}
	if byID["kuma"] == nil || byID["kuma"]["compatible"] != true {
		t.Fatalf("kuma missing or incompatible: %v", byID["kuma"])
	}
	if byID["temp"]["update"] != true || byID["temp"]["installed_version"] != "1.0.0" {
		t.Errorf("temp should be installed with an update: %v", byID["temp"])
	}
	if old, _ := p.Catalog("abc123", "2.2.5"); old != nil {
		for _, e := range old["plugins"].([]map[string]any) {
			if e["id"] == "kuma" && e["compatible"] != false {
				t.Error("kuma needs 2.2.6; a 2.2.5 panel should be told")
			}
		}
	}

	files, err := CatalogFiles("abc123", "kuma")
	if err != nil {
		t.Fatal(err)
	}
	bp, err := p.InstallFiles(files, "")
	if err != nil || bp.manifest.ID != "kuma" || bp.state.Linked != "" {
		t.Fatalf("install from the catalog: %v %+v", err, bp)
	}
}

// A build whose commit is not on GitHub (a local one) still gets the
// catalog, from main.
func TestCatalogFallsBackToMain(t *testing.T) {
	serveRepo(t)
	p, _ := newTestPlugins(t)
	out, err := p.Catalog("deadbeef", "2.2.6")
	if err != nil || out["ref"] != "main" {
		t.Fatalf("%v %v", out["ref"], err)
	}
	if _, err := p.Catalog("../../etc", "2.2.6"); err == nil {
		t.Error("a ref with a path in it was fetched")
	}
}

// The catalog is what people install with one click: every entry must point
// at a package that loads, under the same id and version.
func TestCatalogIndexMatchesThePackages(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "plugins", "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	var idx catalogIndex
	if err := json.Unmarshal(raw, &idx); err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, e := range idx.Plugins {
		if !catalogPathRe.MatchString(e.Path) || slices.Contains(ids, e.ID) || e.Name == "" || e.Description == "" {
			t.Errorf("bad entry %+v", e)
		}
		ids = append(ids, e.ID)
		files, err := readPackage(filepath.Join("..", "plugins", filepath.FromSlash(e.Path)))
		if err != nil {
			t.Errorf("%s: %v", e.ID, err)
			continue
		}
		bp, err := parsePackage(files)
		if err != nil {
			t.Errorf("%s: %v", e.ID, err)
			continue
		}
		if bp.manifest.ID != e.ID || bp.manifest.Version != e.Version {
			t.Errorf("%s: index says %s %s, manifest %s %s", e.Path, e.ID, e.Version, bp.manifest.ID, bp.manifest.Version)
		}
	}
	_ = plugin.MetricKey
}
