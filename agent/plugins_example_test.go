package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
)

// The example in plugins/temps is what people copy, so it has to load and run
// clean. On a Linux machine with sensors this also shows what it reads.
func TestShippedTempsPluginRuns(t *testing.T) {
	dir := filepath.Join("..", "plugins", "temps")
	manifest, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	lua, err := os.ReadFile(filepath.Join(dir, "agent.lua"))
	if err != nil {
		t.Fatal(err)
	}
	h := NewPluginHost(&Config{path: filepath.Join(t.TempDir(), "config.json")})
	if err := h.Sync([]shared.PluginBundle{{ID: "temps", Version: "1", SHA256: "x", Manifest: manifest, AgentLua: string(lua)}}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond) // the first run of beacle.every starts at once
	values, status := h.Snapshot()
	if len(status) != 1 || status[0].Error != "" {
		t.Fatalf("status: %+v", status)
	}
	t.Logf("readings on this machine: %v", values)
}
