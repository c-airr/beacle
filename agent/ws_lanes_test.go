package main

import "testing"

func TestCommandLane(t *testing.T) {
	for in, want := range map[string]string{
		"/api/fs/upload":                 "fs/upload",
		"/api/fs/dir?path=/root":         "fs/dir",
		"/api/proxy/sites/abc":           "proxy/sites",
		"/api/system/updates/apply":      "system/updates",
		"/api/proxy":                     "proxy/",
		"/api/docker/containers/x/start": "docker/containers",
	} {
		if got := commandLane(in); got != want {
			t.Errorf("%s: got %q, want %q", in, got, want)
		}
	}
}
