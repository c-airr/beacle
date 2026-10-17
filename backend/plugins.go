package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"beacle/shared"
	"beacle/shared/plugin"

	lua "github.com/yuin/gopher-lua"
)

const (
	pluginFileMax = 1 << 20
	// viewTimeout bounds a slot function: it runs while the panel waits.
	viewTimeout = 500 * time.Millisecond
	syncTimeout = 30 * time.Second
)

var pluginFiles = []string{"manifest.json", "agent.lua", "backend.lua"}

// Plugins installs plugins, runs their backend parts and pushes their agent
// parts to every server. On disk: <data>/plugins/<id>/ holds the three
// package files, state.json and the backend part's store.json.
type Plugins struct {
	dir      string
	store    *Store
	hub      *Hub
	agentHub *AgentHub

	// Set by main before Start: the panel's API for beacle.api, alerts and
	// history for backend parts' alerts and metrics. Each may be nil (tests).
	api     http.Handler
	alerts  *AlertEngine
	history *History

	mu   sync.Mutex
	list map[string]*backendPlugin
	// syncErr[vps][plugin-less]: why the last push to a server failed.
	syncErr map[string]string
	// updateTried[vps]: when an agent too old for plugins was last updated.
	updateTried map[string]time.Time
}

type pluginState struct {
	Enabled    bool     `json:"enabled"`
	DisabledOn []string `json:"disabled_on,omitempty"`
	// Linked is the folder it was installed from; it is reloaded whenever a
	// file there changes, so a plugin can be written in place.
	Linked string `json:"linked,omitempty"`
	// Config is what the user set in the plugin's settings form.
	Config map[string]any `json:"config,omitempty"`
}

type backendPlugin struct {
	manifest plugin.Manifest
	files    map[string]string
	sha      string
	state    pluginState
	modTime  time.Time // of the linked folder's files at the last load
	rt       *plugin.Runtime

	mu    sync.Mutex // registrations may also come from handlers, not only the load
	slots []pluginSlot
	texts map[string]string
	hide  []string
}

type pluginSlot struct {
	name string
	opts map[string]any
	fn   *lua.LFunction
}

// uiPrelude defines the ui.* block constructors. Kept on one line so error
// line numbers in backend.lua stay right. ui.card is a column marked card:
// a panel from before cards draws it as a plain column.
const uiPrelude = `ui = {} for _, t in ipairs({"label","stat","bar","chart","table","button","input","row","column","link","toggle","select","code"}) do ui[t] = function(p) if type(p) ~= "table" then p = { text = tostring(p) } end local c = {} for i, v in ipairs(p) do c[i] = v end for i = #p, 1, -1 do p[i] = nil end if #c > 0 then p.children = c end p.type = t return p end end ui.card = function(p) p = ui.column(p) p.card = true return p end `

func NewPlugins(dataDir string, store *Store, hub *Hub, agentHub *AgentHub) *Plugins {
	p := &Plugins{
		dir: filepath.Join(dataDir, "plugins"), store: store, hub: hub, agentHub: agentHub,
		list: map[string]*backendPlugin{}, syncErr: map[string]string{}, updateTried: map[string]time.Time{},
	}
	entries, _ := os.ReadDir(p.dir)
	for _, e := range entries {
		bp, err := p.loadInstalled(e.Name())
		if err != nil {
			log.Printf("plugins: %s: %v", e.Name(), err)
			continue
		}
		p.list[bp.manifest.ID] = bp
	}
	return p
}

// Start runs the installed backend parts, once api, alerts and history are
// set: a plugin may call beacle.api from its top level.
func (p *Plugins) Start() {
	p.mu.Lock()
	var on []*backendPlugin
	for _, bp := range p.list {
		if bp.state.Enabled {
			on = append(on, bp)
		}
	}
	p.mu.Unlock()
	for _, bp := range on {
		p.startBackend(bp)
	}
}

func (p *Plugins) loadInstalled(id string) (*backendPlugin, error) {
	dir := filepath.Join(p.dir, id)
	files := map[string]string{}
	for _, name := range pluginFiles {
		if b, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
			files[name] = string(b)
		}
	}
	bp, err := parsePackage(files)
	if err != nil {
		return nil, err
	}
	if b, err := os.ReadFile(filepath.Join(dir, "state.json")); err == nil {
		_ = json.Unmarshal(b, &bp.state)
	}
	if bp.state.Linked != "" {
		bp.modTime = linkedModTime(bp.state.Linked)
	}
	return bp, nil
}

// readPackage reads the package files from a folder or a .zip. In a zip they
// may sit at the root or inside one top folder, as zipping a folder makes.
func readPackage(src string) (map[string]string, error) {
	files := map[string]string{}
	st, err := os.Stat(src)
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		for _, name := range pluginFiles {
			f, err := os.Open(filepath.Join(src, name))
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			if err != nil {
				return nil, err
			}
			b, err := io.ReadAll(io.LimitReader(f, pluginFileMax+1))
			f.Close()
			if err != nil {
				return nil, err
			}
			if len(b) > pluginFileMax {
				return nil, fmt.Errorf("%s is larger than 1 MiB", name)
			}
			files[name] = string(b)
		}
		return files, nil
	}
	zr, err := zip.OpenReader(src)
	if err != nil {
		return nil, fmt.Errorf("not a folder or a .zip: %w", err)
	}
	defer zr.Close()
	for _, f := range zr.File {
		// Windows PowerShell's Compress-Archive writes backslashes.
		entry := strings.ReplaceAll(f.Name, `\`, "/")
		name := path.Base(entry)
		if dir := path.Dir(entry); dir != "." && strings.Contains(dir, "/") {
			continue // deeper than one top folder
		}
		if !slices.Contains(pluginFiles, name) || f.FileInfo().IsDir() {
			continue
		}
		if _, dup := files[name]; dup {
			return nil, fmt.Errorf("the zip holds %s twice", name)
		}
		if f.UncompressedSize64 > pluginFileMax {
			return nil, fmt.Errorf("%s is larger than 1 MiB", name)
		}
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		b, err := io.ReadAll(io.LimitReader(rc, pluginFileMax+1))
		rc.Close()
		if err != nil {
			return nil, err
		}
		files[name] = string(b)
	}
	return files, nil
}

// parsePackage validates the manifest and that both Lua parts compile.
func parsePackage(files map[string]string) (*backendPlugin, error) {
	raw, ok := files["manifest.json"]
	if !ok {
		return nil, errors.New("manifest.json is missing")
	}
	m, err := plugin.ParseManifest([]byte(raw))
	if err != nil {
		return nil, err
	}
	if files["agent.lua"] == "" && files["backend.lua"] == "" {
		return nil, errors.New("the package has neither agent.lua nor backend.lua")
	}
	L := lua.NewState(lua.Options{SkipOpenLibs: true})
	defer L.Close()
	for _, name := range []string{"agent.lua", "backend.lua"} {
		if src := files[name]; src != "" {
			if _, err := L.Load(strings.NewReader(src), name); err != nil {
				return nil, err
			}
		}
	}
	sum := sha256.Sum256([]byte(raw + "\x00" + files["agent.lua"]))
	return &backendPlugin{manifest: m, files: files, sha: hex.EncodeToString(sum[:]), state: pluginState{Enabled: true}}, nil
}

// Inspect reads a package without installing it, for the confirmation the
// user sees: what it may do, and whether that is more than what is installed.
func (p *Plugins) Inspect(src string) (map[string]any, error) {
	files, err := readPackage(src)
	if err != nil {
		return nil, err
	}
	bp, err := parsePackage(files)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"manifest": bp.manifest, "has_agent": files["agent.lua"] != "", "has_backend": files["backend.lua"] != ""}
	p.mu.Lock()
	if old := p.list[bp.manifest.ID]; old != nil {
		out["installed_version"] = old.manifest.Version
		out["new_permissions"] = !permsCovered(bp.manifest.Permissions, old.manifest.Permissions)
	}
	p.mu.Unlock()
	return out, nil
}

func permsCovered(want, have plugin.Permissions) bool {
	for _, pair := range [][2][]string{{want.Read, have.Read}, {want.Exec, have.Exec}, {want.HTTP, have.HTTP}, {want.Write, have.Write}, {want.API, have.API}} {
		for _, w := range pair[0] {
			if !slices.Contains(pair[1], w) {
				return false
			}
		}
	}
	return true
}

// Install copies a package in (replacing an installed one with the same id,
// keeping its settings) and starts it everywhere.
func (p *Plugins) Install(src string) (*backendPlugin, error) {
	files, err := readPackage(src)
	if err != nil {
		return nil, err
	}
	bp, err := parsePackage(files)
	if err != nil {
		return nil, err
	}
	if st, err := os.Stat(src); err == nil && st.IsDir() {
		abs, _ := filepath.Abs(src)
		bp.state.Linked = abs
		bp.modTime = linkedModTime(abs)
	}
	id := bp.manifest.ID
	p.mu.Lock()
	old := p.list[id]
	if old != nil {
		linked := bp.state.Linked
		bp.state = old.state
		bp.state.Linked = linked
	}
	p.mu.Unlock()
	if err := p.writeInstalled(bp); err != nil {
		return nil, err
	}
	p.replace(id, bp)
	return bp, nil
}

func (p *Plugins) writeInstalled(bp *backendPlugin) error {
	dir := filepath.Join(p.dir, bp.manifest.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	for _, name := range pluginFiles {
		target := filepath.Join(dir, name)
		if src, ok := bp.files[name]; ok {
			if err := os.WriteFile(target, []byte(src), 0o600); err != nil {
				return err
			}
		} else {
			_ = os.Remove(target)
		}
	}
	return p.writeState(bp)
}

func (p *Plugins) writeState(bp *backendPlugin) error {
	b, _ := json.MarshalIndent(bp.state, "", "  ")
	return os.WriteFile(filepath.Join(p.dir, bp.manifest.ID, "state.json"), b, 0o600)
}

// replace swaps in a new version (nil removes), restarts the backend part and
// pushes the change to the servers.
func (p *Plugins) replace(id string, bp *backendPlugin) {
	p.mu.Lock()
	var stop *plugin.Runtime
	if old := p.list[id]; old != nil {
		stop = old.rt
	}
	if bp == nil {
		delete(p.list, id)
	} else {
		p.list[id] = bp
	}
	p.mu.Unlock()
	if stop != nil {
		stop.Close()
	}
	if bp != nil && bp.state.Enabled {
		p.startBackend(bp)
	}
	p.changed()
}

func (p *Plugins) changed() {
	p.hub.Broadcast(shared.WSPlugins, nil)
	go p.SyncAll()
}

var errNoPlugin = errors.New("no such plugin")

// SetState turns a plugin on or off, everywhere or on some servers, and
// saves its settings. New settings restart it.
func (p *Plugins) SetState(id string, enabled *bool, disabledOn *[]string, config map[string]any) error {
	p.mu.Lock()
	bp := p.list[id]
	if bp == nil {
		p.mu.Unlock()
		return errNoPlugin
	}
	if config != nil {
		clean, err := cleanConfig(bp.manifest, bp.state.Config, config)
		if err != nil {
			p.mu.Unlock()
			return err
		}
		bp.state.Config = clean
	}
	if disabledOn != nil {
		bp.state.DisabledOn = *disabledOn
	}
	toggle := enabled != nil && *enabled != bp.state.Enabled
	if toggle {
		bp.state.Enabled = *enabled
	}
	restart := toggle || (config != nil && bp.state.Enabled)
	var stop *plugin.Runtime
	if restart {
		stop, bp.rt = bp.rt, nil
	}
	err := p.writeState(bp)
	p.mu.Unlock()
	if stop != nil {
		stop.Close()
	}
	if restart && bp.state.Enabled {
		p.startBackend(bp)
	}
	if toggle && !bp.state.Enabled && p.alerts != nil {
		p.alerts.ResolvePluginAll(id)
	}
	if err != nil {
		return err
	}
	p.changed()
	return nil
}

func (p *Plugins) Remove(id string) error {
	p.mu.Lock()
	_, ok := p.list[id]
	p.mu.Unlock()
	if !ok {
		return errNoPlugin
	}
	p.replace(id, nil)
	if p.alerts != nil {
		p.alerts.ResolvePluginAll(id)
	}
	return os.RemoveAll(filepath.Join(p.dir, id))
}

// startBackend runs backend.lua, if there is one, with the backend API.
func (p *Plugins) startBackend(bp *backendPlugin) {
	bp.mu.Lock()
	bp.slots, bp.texts, bp.hide = nil, map[string]string{}, nil
	bp.mu.Unlock()
	src := bp.files["backend.lua"]
	if src == "" {
		return
	}
	rt := plugin.New(bp.manifest, filepath.Join(p.dir, bp.manifest.ID, "store.json"))
	rt.Config = plugin.ConfigValues(bp.manifest, bp.state.Config, false)
	rt.OpenHTTP()
	rt.OpenMetrics()
	rt.Set("servers", p.luaServers)
	rt.Set("value", p.luaValue(bp.manifest.ID))
	rt.Set("call", p.luaCall(bp.manifest))
	rt.Set("api", p.luaAPI(bp.manifest))
	rt.Set("alert", p.luaAlert(bp.manifest.ID))
	rt.Set("resolve", p.luaResolve(bp.manifest.ID))
	rt.Set("slot", func(L *lua.LState) int {
		name := L.CheckString(1)
		opts, _ := plugin.ToGo(L.OptTable(2, L.NewTable())).(map[string]any)
		bp.mu.Lock()
		bp.slots = append(bp.slots, pluginSlot{name: name, opts: opts, fn: L.CheckFunction(3)})
		bp.mu.Unlock()
		return 0
	})
	rt.Set("text", func(L *lua.LState) int {
		bp.mu.Lock()
		bp.texts[L.CheckString(1)] = L.CheckString(2)
		bp.mu.Unlock()
		return 0
	})
	rt.Set("hide", func(L *lua.LState) int {
		bp.mu.Lock()
		bp.hide = append(bp.hide, L.CheckString(1))
		bp.mu.Unlock()
		return 0
	})
	p.mu.Lock()
	bp.rt = rt
	p.mu.Unlock()
	if err := rt.Load(uiPrelude, "ui"); err == nil {
		_ = rt.Load(src, bp.manifest.ID+"/backend.lua")
	}
}

func (p *Plugins) luaServers(L *lua.LState) int {
	t := L.NewTable()
	for _, v := range p.store.ListVPS() {
		t.Append(plugin.FromGo(L, serverTable(v, p.agentHub.Connected(v.ID))))
	}
	L.Push(t)
	return 1
}

func serverTable(v shared.VPS, online bool) map[string]any {
	tags := v.Tags
	if tags == nil {
		tags = []string{}
	}
	return map[string]any{
		"id": v.ID, "name": v.Name, "status": string(v.Status), "online": online,
		"host": v.Host, "public_ip": v.PublicIP, "tags": tags, "location": v.Location,
		"agent_version": v.AgentVer,
	}
}

// coreMetric is the panel's own reading of a server, for "system.<name>".
func coreMetric(m shared.SystemMetrics, name string) (float64, bool) {
	switch name {
	case "cpu":
		return m.CPUPercent, true
	case "mem":
		return m.MemPercent, true
	case "load1":
		return m.Load1, true
	case "disk":
		return shared.SampleFrom(m).Disk, true
	case "rx":
		return float64(shared.SampleFrom(m).RxPerS), true
	case "tx":
		return float64(shared.SampleFrom(m).TxPerS), true
	}
	return 0, false
}

// luaValue: beacle.value(server, metric). A bare metric name means one of
// this plugin's own; "system.cpu" (mem, disk, load1, rx, tx) is the panel's
// own reading; server "local" is this computer's backend parts.
func (p *Plugins) luaValue(id string) lua.LGFunction {
	return func(L *lua.LState) int {
		vps, key := L.CheckString(1), L.CheckString(2)
		if !strings.Contains(key, ".") {
			key = plugin.MetricKey(id, key)
		}
		if vps == localID {
			if v, ok := p.localValues()[key]; ok {
				L.Push(lua.LNumber(v))
				return 1
			}
		} else if snap := p.store.GetSnapshot(vps); snap != nil {
			if name, ok := strings.CutPrefix(key, "system."); ok {
				if v, ok := coreMetric(snap.Metrics, name); ok {
					L.Push(lua.LNumber(v))
					return 1
				}
			}
			if v, ok := snap.Metrics.Plugins[key]; ok {
				L.Push(lua.LNumber(v))
				return 1
			}
		}
		L.Push(lua.LNil)
		return 1
	}
}

// luaCall: beacle.call(server, action, args) runs the agent part's handler.
func (p *Plugins) luaCall(m plugin.Manifest) lua.LGFunction {
	return func(L *lua.LState) int {
		body, _ := json.Marshal(shared.PluginCall{ID: m.ID, Action: L.CheckString(2), Args: plugin.ToGo(L.Get(3))})
		resp, code, err := p.agentHub.Request(L.CheckString(1), http.MethodPost, "/api/plugins/call", body, m.CallTimeout())
		if err == nil && code != http.StatusOK {
			var e shared.APIError
			_ = json.Unmarshal(resp, &e)
			err = errors.New(e.Error)
		}
		if err != nil {
			L.Push(lua.LNil)
			L.Push(lua.LString(err.Error()))
			return 2
		}
		var out struct {
			Result any `json:"result"`
		}
		_ = json.Unmarshal(resp, &out)
		L.Push(plugin.FromGo(L, out.Result))
		return 1
	}
}

// SyncAll pushes the agent parts to every connected server.
func (p *Plugins) SyncAll() {
	for _, v := range p.store.ListVPS() {
		if p.agentHub.Connected(v.ID) {
			p.SyncAgent(v.ID)
		}
	}
}

// SyncAgent sends one server the complete list it should run.
func (p *Plugins) SyncAgent(vpsID string) {
	bundles := []shared.PluginBundle{}
	p.mu.Lock()
	for _, bp := range p.list {
		if bp.state.Enabled && bp.files["agent.lua"] != "" && !slices.Contains(bp.state.DisabledOn, vpsID) {
			config := plugin.ConfigValues(bp.manifest, bp.state.Config, true)
			raw, _ := json.Marshal(config)
			sum := sha256.Sum256([]byte(bp.sha + "\x00" + string(raw)))
			bundles = append(bundles, shared.PluginBundle{
				ID: bp.manifest.ID, Version: bp.manifest.Version, SHA256: hex.EncodeToString(sum[:]),
				Manifest: json.RawMessage(bp.files["manifest.json"]), AgentLua: bp.files["agent.lua"], Config: config,
			})
		}
	}
	p.mu.Unlock()
	body, _ := json.Marshal(bundles)
	resp, code, err := p.agentHub.Request(vpsID, http.MethodPost, "/api/plugins/sync", body, syncTimeout)
	msg := ""
	switch {
	case err != nil:
		msg = err.Error()
	case code == http.StatusNotFound:
		msg = "agent too old (plugins need 2.2.0)"
	case code != http.StatusOK:
		var e shared.APIError
		_ = json.Unmarshal(resp, &e)
		msg = e.Error
	}
	p.mu.Lock()
	changed := p.syncErr[vpsID] != msg
	if msg == "" {
		delete(p.syncErr, vpsID)
	} else {
		p.syncErr[vpsID] = msg
	}
	p.mu.Unlock()
	if changed {
		p.hub.Broadcast(shared.WSPlugins, nil)
	}
	if code == http.StatusOK {
		p.agentHub.RequestRefresh(vpsID) // status shows up without waiting a tick
	}
	if len(bundles) > 0 && (code == http.StatusOK || code == http.StatusNotFound) {
		go p.maybeUpdateAgent(vpsID) // minutes, and SyncAll goes server by server
	}
}

// WatchLinked reloads plugins installed from a folder when a file changes.
func (p *Plugins) WatchLinked() {
	for range time.Tick(time.Second) {
		p.mu.Lock()
		var stale []*backendPlugin
		for _, bp := range p.list {
			if bp.state.Linked != "" && !linkedModTime(bp.state.Linked).Equal(bp.modTime) {
				stale = append(stale, bp)
			}
		}
		p.mu.Unlock()
		for _, bp := range stale {
			if _, err := p.Install(bp.state.Linked); err != nil {
				// Shown in the plugin's log until the next save fixes it.
				p.mu.Lock()
				bp.modTime = linkedModTime(bp.state.Linked)
				rt := bp.rt
				p.mu.Unlock()
				if rt != nil {
					rt.Logf("reload failed: %v", err)
				}
				log.Printf("plugins: reload %s: %v", bp.manifest.ID, err)
			}
		}
	}
}

func linkedModTime(dir string) time.Time {
	var latest time.Time
	for _, name := range pluginFiles {
		if st, err := os.Stat(filepath.Join(dir, name)); err == nil && st.ModTime().After(latest) {
			latest = st.ModTime()
		}
	}
	return latest
}

// ---------------------------------------------------------------------------
// What the panel reads

type pluginView struct {
	ID         string                       `json:"id"`
	Name       string                       `json:"name"`
	Version    string                       `json:"version"`
	Enabled    bool                         `json:"enabled"`
	Linked     string                       `json:"linked,omitempty"`
	DisabledOn []string                     `json:"disabled_on"`
	Perms      plugin.Permissions           `json:"permissions"`
	Metrics    map[string]plugin.MetricDef  `json:"metrics"`
	Config     []plugin.ConfigField         `json:"config,omitempty"`
	Values     map[string]any               `json:"values,omitempty"` // a secret only says whether it is set
	HasAgent   bool                         `json:"has_agent"`
	HasBackend bool                         `json:"has_backend"`
	Error      string                       `json:"error,omitempty"`
	Servers    map[string]map[string]string `json:"servers"` // vps -> {state, error}
}

// List is GET /api/plugins: the plugins, plus everything the panel applies
// globally (text overrides, hidden ids, extra tabs).
func (p *Plugins) List() map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	views := []pluginView{}
	texts := map[string]string{}
	hide := []string{}
	tabs := []map[string]any{}
	vpsList := p.store.ListVPS()
	ids := make([]string, 0, len(p.list))
	for id := range p.list {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		bp := p.list[id]
		v := pluginView{
			ID: id, Name: bp.manifest.Name, Version: bp.manifest.Version, Enabled: bp.state.Enabled,
			Linked: bp.state.Linked, DisabledOn: append([]string{}, bp.state.DisabledOn...),
			Perms: bp.manifest.Permissions, Metrics: bp.manifest.Metrics,
			Config: bp.manifest.Config, Values: maskSecrets(bp.manifest, bp.state.Config),
			HasAgent: bp.files["agent.lua"] != "", HasBackend: bp.files["backend.lua"] != "",
			Servers: map[string]map[string]string{},
		}
		if bp.rt != nil {
			v.Error = bp.rt.Err()
		}
		if v.HasAgent && bp.state.Enabled {
			for _, vps := range vpsList {
				v.Servers[vps.ID] = p.serverState(bp, vps.ID)
			}
		}
		views = append(views, v)
		if !bp.state.Enabled {
			continue
		}
		bp.mu.Lock()
		for k, t := range bp.texts {
			texts[k] = t
		}
		hide = append(hide, bp.hide...)
		for _, s := range bp.slots {
			if s.name == "nav.tab" {
				tabs = append(tabs, map[string]any{"plugin": id, "id": s.opts["id"], "title": s.opts["title"], "icon": s.opts["icon"]})
			}
		}
		bp.mu.Unlock()
	}
	return map[string]any{"plugins": views, "texts": texts, "hide": hide, "tabs": tabs}
}

func maskSecrets(m plugin.Manifest, values map[string]any) map[string]any {
	out := map[string]any{}
	for _, f := range m.Config {
		if v, ok := values[f.Key]; ok {
			if f.Type == "secret" {
				v = v != ""
			}
			out[f.Key] = v
		}
	}
	return out
}

// serverState is called with p.mu held.
func (p *Plugins) serverState(bp *backendPlugin, vpsID string) map[string]string {
	if slices.Contains(bp.state.DisabledOn, vpsID) {
		return map[string]string{"state": "off"}
	}
	if msg := p.syncErr[vpsID]; msg != "" {
		return map[string]string{"state": "error", "error": msg}
	}
	if snap := p.store.GetSnapshot(vpsID); snap != nil {
		for _, st := range snap.Metrics.PluginStatus {
			if st.ID == bp.manifest.ID {
				if st.Error != "" {
					return map[string]string{"state": "error", "error": st.Error}
				}
				return map[string]string{"state": "running"}
			}
		}
	}
	return map[string]string{"state": "pending"}
}

// MetricDefs is every enabled plugin's metrics keyed "<plugin>.<metric>",
// for alerting.
func (p *Plugins) MetricDefs() map[string]plugin.MetricDef {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := map[string]plugin.MetricDef{}
	for id, bp := range p.list {
		if !bp.state.Enabled {
			continue
		}
		for name, d := range bp.manifest.Metrics {
			out[plugin.MetricKey(id, name)] = d
		}
	}
	return out
}

type slotRender struct {
	Plugin string         `json:"plugin"`
	Opts   map[string]any `json:"opts"`
	Blocks any            `json:"blocks,omitempty"`
	Cells  map[string]any `json:"cells,omitempty"` // servers.column: vps -> block
	Error  string         `json:"error,omitempty"`
}

// Render runs every enabled plugin's functions for one slot. vpsID is the
// server a server.section is for; servers.column renders a cell per server.
func (p *Plugins) Render(slot, vpsID, tab string) []slotRender {
	type job struct {
		id string
		rt *plugin.Runtime
		s  pluginSlot
	}
	var jobs []job
	p.mu.Lock()
	for id, bp := range p.list {
		if !bp.state.Enabled || bp.rt == nil {
			continue
		}
		bp.mu.Lock()
		for _, s := range bp.slots {
			if s.name == slot && (tab == "" || fmt.Sprint(s.opts["id"]) == tab) {
				jobs = append(jobs, job{id, bp.rt, s})
			}
		}
		bp.mu.Unlock()
	}
	p.mu.Unlock()
	sort.SliceStable(jobs, func(i, j int) bool { return jobs[i].id < jobs[j].id })

	out := []slotRender{}
	for _, j := range jobs {
		r := slotRender{Plugin: j.id, Opts: j.s.opts}
		switch slot {
		case "servers.column":
			r.Cells = map[string]any{}
			for _, v := range p.store.ListVPS() {
				block, err := p.view(j.rt, j.s.fn, &v)
				if err != nil {
					r.Error = err.Error()
					break
				}
				r.Cells[v.ID] = block
			}
		case "server.section", "server.actions":
			e := p.store.GetVPS(vpsID)
			if e == nil {
				continue
			}
			r.Blocks, _ = p.viewOrErr(j.rt, j.s.fn, &e.VPS, &r)
		default:
			r.Blocks, _ = p.viewOrErr(j.rt, j.s.fn, nil, &r)
		}
		out = append(out, r)
	}
	return out
}

func (p *Plugins) viewOrErr(rt *plugin.Runtime, fn *lua.LFunction, v *shared.VPS, r *slotRender) (any, error) {
	b, err := p.view(rt, fn, v)
	if err != nil {
		r.Error = err.Error()
	}
	return b, err
}

func (p *Plugins) view(rt *plugin.Runtime, fn *lua.LFunction, v *shared.VPS) (any, error) {
	if v == nil {
		return rt.Call(fn, viewTimeout)
	}
	return rt.Call(fn, viewTimeout, serverTable(*v, p.agentHub.Connected(v.ID)))
}

// Action runs a beacle.on handler for a button or input. A string it returns
// is shown to the user.
func (p *Plugins) Action(id, name string, args map[string]any) (any, error) {
	rt, _ := p.runtime(id)
	if rt == nil {
		return nil, errors.New("plugin not running")
	}
	return rt.Handle(name, args, rt.Manifest.CallTimeout())
}

func (p *Plugins) Logs(id string) ([]string, bool) {
	rt, ok := p.runtime(id)
	if rt == nil {
		return []string{}, ok
	}
	return rt.Logs(), ok
}

// runtime is the backend part of a plugin, nil when it has none or is off.
func (p *Plugins) runtime(id string) (*plugin.Runtime, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	bp := p.list[id]
	if bp == nil {
		return nil, false
	}
	return bp.rt, true
}
