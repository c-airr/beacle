package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"beacle/shared"
	"beacle/shared/plugin"
)

// PluginHost runs the agent parts of plugins. The panel pushes the complete
// list; a copy stays on disk so plugins keep running across a restart while
// the panel is away.
type PluginHost struct {
	dir     string
	mu      sync.Mutex
	running map[string]*agentPlugin
}

type agentPlugin struct {
	bundle shared.PluginBundle
	rt     *plugin.Runtime // nil when the manifest itself was refused
	err    string
}

func NewPluginHost(cfg *Config) *PluginHost {
	h := &PluginHost{dir: filepath.Join(cfg.StateDir(), "plugins"), running: map[string]*agentPlugin{}}
	if cfg.DisablePlugins {
		return h
	}
	entries, _ := os.ReadDir(h.dir)
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join(h.dir, e.Name(), "bundle.json"))
		if err != nil {
			continue
		}
		var bundle shared.PluginBundle
		if json.Unmarshal(b, &bundle) == nil {
			h.start(bundle)
		}
	}
	return h
}

// Sync makes the running set exactly bundles: new ones start, changed ones
// restart, missing ones stop and their files (store included) go.
func (h *PluginHost) Sync(bundles []shared.PluginBundle) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	want := map[string]shared.PluginBundle{}
	for _, b := range bundles {
		// The id names a directory; a manifest that fails validation never
		// gets that far.
		m, err := plugin.ParseManifest(b.Manifest)
		if err != nil {
			return err
		}
		if m.ID != b.ID {
			return fmt.Errorf("bundle %q carries manifest %q", b.ID, m.ID)
		}
		want[b.ID] = b
	}
	for id, p := range h.running {
		b, ok := want[id]
		if ok && b.SHA256 == p.bundle.SHA256 {
			continue
		}
		if p.rt != nil {
			p.rt.Close()
		}
		delete(h.running, id)
		if !ok {
			_ = os.RemoveAll(filepath.Join(h.dir, id))
		}
	}
	for _, b := range bundles {
		if _, ok := h.running[b.ID]; ok {
			continue
		}
		dir := filepath.Join(h.dir, b.ID)
		raw, _ := json.Marshal(b)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "bundle.json"), raw, 0o600); err != nil {
			return err
		}
		h.start(b)
	}
	return nil
}

// start is called with mu held (or before the host is shared).
func (h *PluginHost) start(b shared.PluginBundle) {
	p := &agentPlugin{bundle: b}
	h.running[b.ID] = p
	m, err := plugin.ParseManifest(b.Manifest)
	if err != nil || m.ID != b.ID {
		p.err = fmt.Sprintf("bad manifest: %v", err)
		return
	}
	p.rt = plugin.New(m, filepath.Join(h.dir, b.ID, "store.json"))
	p.rt.Config = b.Config
	p.rt.OpenSystem()
	p.rt.OpenMetrics()
	p.rt.OpenHTTP()
	if err := p.rt.Load(b.AgentLua, b.ID+"/agent.lua"); err != nil {
		log.Printf("plugin %s: %v", b.ID, err)
	}
}

// Snapshot is what goes into the metrics frame.
func (h *PluginHost) Snapshot() (map[string]float64, []shared.PluginStatus) {
	h.mu.Lock()
	defer h.mu.Unlock()
	var values map[string]float64
	status := make([]shared.PluginStatus, 0, len(h.running))
	for id, p := range h.running {
		st := shared.PluginStatus{ID: id, Version: p.bundle.Version, Error: p.err}
		if p.rt != nil {
			st.Error = p.rt.Err()
			for k, v := range p.rt.Values() {
				if values == nil {
					values = map[string]float64{}
				}
				values[k] = v
			}
		}
		status = append(status, st)
	}
	sort.Slice(status, func(i, j int) bool { return status[i].ID < status[j].ID })
	return values, status
}

// Call runs a beacle.on handler of one plugin.
func (h *PluginHost) Call(c shared.PluginCall) (any, error) {
	h.mu.Lock()
	p := h.running[c.ID]
	h.mu.Unlock()
	if p == nil || p.rt == nil {
		return nil, errors.New("plugin not running: " + c.ID)
	}
	return p.rt.Handle(c.Action, c.Args, p.rt.Manifest.CallTimeout())
}
