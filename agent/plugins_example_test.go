package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
)

// The example in plugins/demo/temp is what people copy, so it has to load and run
// clean. On a Linux machine with sensors this also shows what it reads.
func TestShippedTempsPluginRuns(t *testing.T) {
	dir := filepath.Join("..", "plugins", "demo", "temp")
	manifest, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	lua, err := os.ReadFile(filepath.Join(dir, "agent.lua"))
	if err != nil {
		t.Fatal(err)
	}
	h := NewPluginHost(&Config{path: filepath.Join(t.TempDir(), "config.json")})
	if err := h.Sync([]shared.PluginBundle{{ID: "temp", Version: "1", SHA256: "x", Manifest: manifest, AgentLua: string(lua)}}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(500 * time.Millisecond) // the first run of beacle.every starts at once
	values, status := h.Snapshot()
	if len(status) != 1 || status[0].Error != "" {
		t.Fatalf("status: %+v", status)
	}
	t.Logf("readings on this machine: %v", values)
}

// One failed nvidia-smi — the driver busy, a timeout — used to switch the GPU
// reading off until the agent restarted. Only a missing nvidia-smi should.
func TestShippedTempsPluginSurvivesAFailedNvidiaSmi(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the plugin's second reading")
	}
	bin := t.TempDir()
	state := filepath.Join(bin, "ran")
	script := "#!/bin/sh\nif [ -e " + state + " ]; then echo 55; exit 0; fi\ntouch " + state + "\nexit 9\n"
	if err := os.WriteFile(filepath.Join(bin, "nvidia-smi"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))

	dir := filepath.Join("..", "plugins", "demo", "temp")
	manifest, _ := os.ReadFile(filepath.Join(dir, "manifest.json"))
	lua, _ := os.ReadFile(filepath.Join(dir, "agent.lua"))
	h := NewPluginHost(&Config{path: filepath.Join(t.TempDir(), "config.json")})
	if err := h.Sync([]shared.PluginBundle{{ID: "temp", Version: "1", SHA256: "x", Manifest: manifest, AgentLua: string(lua)}}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = h.Sync(nil) })
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if values, _ := h.Snapshot(); values["temp.gpu_temp"] == 55 {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	values, _ := h.Snapshot()
	t.Fatalf("no GPU reading after nvidia-smi failed once: %v", values)
}
