package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
	"beacle/shared/plugin"
)

const testManifest = `{"id":"temps","name":"Temps","version":"1.0.0",
 "permissions":{"read":["/sys/class/thermal"]},
 "metrics":{"cpu_temp":{"label":"CPU","unit":"°C","warn":80,"crit":90}}}`

const testBackend = `
beacle.text("alerts", "Fires")
beacle.hide("overview.links")
beacle.slot("nav.tab", { id = "temps", title = "Temps", icon = "thermostat" }, function()
  return { ui.label("hello"), ui.row{ ui.stat{ metric = "temps.cpu_temp" }, ui.bar{ value = 40 } } }
end)
beacle.slot("server.section", { title = "Temperatures" }, function(server)
  return { ui.label(server.name) }
end)
beacle.slot("servers.column", { title = "CPU °C" }, function(server)
  return ui.stat{ metric = "temps.cpu_temp", unit = "°C" }
end)
beacle.on("reset", function(args) return "reset " .. args.server end)
`

func newTestPlugins(t *testing.T) (*Plugins, *Store) {
	t.Helper()
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	hub := NewHub()
	p := NewPlugins(dir, store, hub, NewAgentHub(store, hub, nil, nil, nil))
	t.Cleanup(func() {
		for id := range p.list {
			if rt, _ := p.runtime(id); rt != nil {
				rt.Close()
			}
		}
	})
	return p, store
}

func writePkgDir(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, src := range files {
		os.WriteFile(filepath.Join(dir, name), []byte(src), 0o644)
	}
	return dir
}

func writePkgZip(t *testing.T, files map[string]string) string {
	t.Helper()
	return writePkgZipSep(t, files, "/")
}

// sep is how the zip tool separates the top folder from the file.
func writePkgZipSep(t *testing.T, files map[string]string, sep string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "temps.zip")
	f, _ := os.Create(path)
	zw := zip.NewWriter(f)
	for name, src := range files {
		w, _ := zw.Create("temps" + sep + name) // as zipping the folder makes it
		w.Write([]byte(src))
	}
	zw.Close()
	f.Close()
	return path
}

func TestInstallFromZipRendersSlots(t *testing.T) {
	p, store := newTestPlugins(t)
	e := store.CreateVPS("panther", "panther", "100.1.1.1")
	zipPath := writePkgZip(t, map[string]string{"manifest.json": testManifest, "backend.lua": testBackend})
	if _, err := p.Install(zipPath); err != nil {
		t.Fatal(err)
	}

	list := p.List()
	if list["texts"].(map[string]string)["alerts"] != "Fires" || len(list["hide"].([]string)) != 1 {
		t.Fatalf("texts/hide: %v %v", list["texts"], list["hide"])
	}
	if tabs := list["tabs"].([]map[string]any); len(tabs) != 1 || tabs[0]["title"] != "Temps" {
		t.Fatalf("tabs: %v", tabs)
	}

	tab := p.Render("nav.tab", "", "temps")
	if len(tab) != 1 || tab[0].Error != "" {
		t.Fatalf("nav.tab: %+v", tab)
	}
	blocks := tab[0].Blocks.([]any)
	row := blocks[1].(map[string]any)
	if blocks[0].(map[string]any)["text"] != "hello" || row["type"] != "row" || len(row["children"].([]any)) != 2 {
		t.Fatalf("blocks: %v", blocks)
	}

	sec := p.Render("server.section", e.VPS.ID, "")
	if len(sec) != 1 || sec[0].Blocks.([]any)[0].(map[string]any)["text"] != "panther" {
		t.Fatalf("server.section: %+v", sec)
	}
	col := p.Render("servers.column", "", "")
	if len(col) != 1 || col[0].Cells[e.VPS.ID].(map[string]any)["type"] != "stat" {
		t.Fatalf("servers.column: %+v", col)
	}

	res, err := p.Action("temps", "reset", map[string]any{"server": e.VPS.ID})
	if err != nil || res != "reset "+e.VPS.ID {
		t.Fatalf("action: %v %v", res, err)
	}
}

func TestInstallFromWindowsPowerShellZip(t *testing.T) {
	p, _ := newTestPlugins(t)
	if _, err := p.Install(writePkgZipSep(t, map[string]string{"manifest.json": testManifest, "agent.lua": "--"}, `\`)); err != nil {
		t.Fatal(err)
	}
}

func TestInstallFromFolderIsLinkedAndKeepsState(t *testing.T) {
	p, _ := newTestPlugins(t)
	dir := writePkgDir(t, map[string]string{"manifest.json": testManifest, "agent.lua": `beacle.metric("cpu_temp", 1)`})
	bp, err := p.Install(dir)
	if err != nil {
		t.Fatal(err)
	}
	if bp.state.Linked == "" {
		t.Fatal("a folder install is not linked")
	}
	off := false
	if err := p.SetState("temps", &off, nil); err != nil {
		t.Fatal(err)
	}
	// Reinstalling (what a save in the folder does) keeps it switched off.
	bp, err = p.Install(dir)
	if err != nil || bp.state.Enabled {
		t.Fatalf("state after reinstall: %+v %v", bp.state, err)
	}
	// And so does a backend restart.
	p2 := NewPlugins(filepath.Dir(p.dir), p.store, p.hub, p.agentHub)
	if p2.list["temps"] == nil || p2.list["temps"].state.Enabled {
		t.Fatalf("after restart: %+v", p2.list["temps"])
	}
}

// The shipped example renders every slot it registers without an error, with
// and without readings.
func TestShippedTempsPluginRenders(t *testing.T) {
	p, store := newTestPlugins(t)
	e := store.CreateVPS("panther", "panther", "100.1.1.1")
	if _, err := p.Install(filepath.Join("..", "plugins", "temps")); err != nil {
		t.Fatal(err)
	}
	check := func() {
		t.Helper()
		for _, slot := range []string{"servers.column", "server.section", "nav.tab"} {
			for _, r := range p.Render(slot, e.VPS.ID, "") {
				if r.Error != "" {
					t.Errorf("%s: %s", slot, r.Error)
				}
			}
		}
	}
	check()
	store.SetSnapshot(&shared.VPSSnapshot{VPS: e.VPS, Metrics: shared.SystemMetrics{
		Plugins: map[string]float64{"temps.cpu_temp": 61.5, "temps.gpu_temp": 70},
	}})
	check()
}

func TestInspectFlagsNewPermissions(t *testing.T) {
	p, _ := newTestPlugins(t)
	if _, err := p.Install(writePkgDir(t, map[string]string{"manifest.json": testManifest, "agent.lua": "--"})); err != nil {
		t.Fatal(err)
	}
	more := `{"id":"temps","name":"Temps","version":"1.1.0","permissions":{"read":["/sys/class/thermal"],"exec":["nvidia-smi"]}}`
	info, err := p.Inspect(writePkgDir(t, map[string]string{"manifest.json": more, "agent.lua": "--"}))
	if err != nil || info["new_permissions"] != true || info["installed_version"] != "1.0.0" {
		t.Fatalf("inspect: %v %v", info, err)
	}
}

func TestInstallRefusesBrokenPackages(t *testing.T) {
	p, _ := newTestPlugins(t)
	for name, files := range map[string]map[string]string{
		"no manifest":  {"agent.lua": "--"},
		"no code":      {"manifest.json": testManifest},
		"syntax error": {"manifest.json": testManifest, "agent.lua": "this is not lua"},
		"bad manifest": {"manifest.json": `{"id":"../x","name":"x","version":"1"}`, "agent.lua": "--"},
	} {
		if _, err := p.Install(writePkgDir(t, files)); err == nil {
			t.Errorf("%s: installed", name)
		}
	}
	if len(p.list) != 0 {
		t.Fatalf("something was installed: %v", p.list)
	}
}

func TestPluginMetricAlertFiresAndResolves(t *testing.T) {
	store, e := newStoreAndEngine(t)
	defs := map[string]plugin.MetricDef{"temps.cpu_temp": {Label: "CPU", Unit: "°C", Warn: 80, Crit: 90}}
	open := func() []shared.Alert {
		var out []shared.Alert
		for _, a := range store.ListAlerts() {
			if a.Type == shared.AlertPluginMetric && !a.Resolved {
				out = append(out, a)
			}
		}
		return out
	}
	hot := map[string]float64{"temps.cpu_temp": 85}
	e.evaluatePlugins(testVPS, hot, defs) // starts the sustained clock
	if len(open()) != 0 {
		t.Fatal("fired on the first sample")
	}
	e.since["vps1|plugin|temps.cpu_temp"] = time.Now().Add(-time.Minute)
	e.evaluatePlugins(testVPS, hot, defs)
	if a := open(); len(a) != 1 || a[0].Severity != shared.SeverityWarning || a[0].Message != "CPU at 85.0°C (limit 80°C)" {
		t.Fatalf("warn: %+v", a)
	}
	e.evaluatePlugins(testVPS, map[string]float64{"temps.cpu_temp": 95}, defs)
	if a := open(); len(a) != 1 || a[0].Severity != shared.SeverityCritical {
		t.Fatalf("crit: %+v", a)
	}
	e.evaluatePlugins(testVPS, map[string]float64{"temps.cpu_temp": 78}, defs)
	if a := open(); len(a) != 1 {
		t.Fatalf("cleared inside the hysteresis band: %+v", a)
	}
	e.evaluatePlugins(testVPS, map[string]float64{"temps.cpu_temp": 60}, defs)
	if a := open(); len(a) != 0 {
		t.Fatalf("not cleared: %+v", a)
	}

	// A per-server override lowers warn; a vanished metric resolves.
	v := testVPS
	v.Thresholds = &shared.VPSThresholds{Plugins: map[string]float64{"temps.cpu_temp": 50}}
	e.since["vps1|plugin|temps.cpu_temp"] = time.Now().Add(-time.Minute)
	e.evaluatePlugins(v, map[string]float64{"temps.cpu_temp": 60}, defs)
	if len(open()) != 1 {
		t.Fatal("override ignored")
	}
	e.evaluatePlugins(v, nil, defs)
	if a := open(); len(a) != 0 {
		t.Fatalf("vanished metric still alerting: %+v", a)
	}
}
