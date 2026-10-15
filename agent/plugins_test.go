package main

import (
	"os"
	"path/filepath"
	"testing"

	"beacle/shared"
)

func bundle(id, sha, lua string) shared.PluginBundle {
	return shared.PluginBundle{
		ID: id, Version: "1", SHA256: sha, AgentLua: lua,
		Manifest: []byte(`{"id":"` + id + `","name":"N","version":"1","metrics":{"v":{}}}`),
	}
}

func TestPluginSyncStartsRestartsAndRemoves(t *testing.T) {
	cfg := &Config{path: filepath.Join(t.TempDir(), "config.json")}
	h := NewPluginHost(cfg)

	if err := h.Sync([]shared.PluginBundle{
		bundle("a", "1", `beacle.metric("v", 1)`),
		bundle("b", "1", `error("broken")`),
	}); err != nil {
		t.Fatal(err)
	}
	values, status := h.Snapshot()
	if values["a.v"] != 1 || len(status) != 2 || status[0].Error != "" || status[1].Error == "" {
		t.Fatalf("after first sync: %v %+v", values, status)
	}

	// Same hash keeps the running state; a new hash restarts with new code.
	if err := h.Sync([]shared.PluginBundle{bundle("a", "2", `beacle.metric("v", 2)`)}); err != nil {
		t.Fatal(err)
	}
	values, status = h.Snapshot()
	if values["a.v"] != 2 || len(status) != 1 {
		t.Fatalf("after second sync: %v %+v", values, status)
	}
	if _, err := os.Stat(filepath.Join(cfg.StateDir(), "plugins", "b")); !os.IsNotExist(err) {
		t.Fatalf("removed plugin left files behind: %v", err)
	}

	// A restarted agent picks up what was synced last.
	again := NewPluginHost(cfg)
	if values, _ := again.Snapshot(); values["a.v"] != 2 {
		t.Fatalf("after restart: %v", values)
	}
}

func TestPluginSyncRefusesBadIDs(t *testing.T) {
	h := NewPluginHost(&Config{path: filepath.Join(t.TempDir(), "config.json")})
	b := bundle("a", "1", "")
	b.ID = "../../etc"
	if err := h.Sync([]shared.PluginBundle{b}); err == nil {
		t.Fatal("accepted a bundle whose id is not its manifest's")
	}
}

func TestPluginCall(t *testing.T) {
	h := NewPluginHost(&Config{path: filepath.Join(t.TempDir(), "config.json")})
	h.Sync([]shared.PluginBundle{bundle("a", "1", `beacle.on("add", function(x) return x.a + x.b end)`)})
	got, err := h.Call(shared.PluginCall{ID: "a", Action: "add", Args: map[string]any{"a": 2.0, "b": 3.0}})
	if err != nil || got != 5.0 {
		t.Fatalf("call: %v %v", got, err)
	}
}
