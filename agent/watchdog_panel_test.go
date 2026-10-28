package main

import (
	"slices"
	"testing"
	"time"

	"beacle/shared"
)

// The panel going quiet is announced only when asked for, once, after the
// chosen time, and followed by a notice when it is back.
func TestPanelQuietNotice(t *testing.T) {
	f := withFakeFleet(t, true, map[string]bool{"a": true, "b": true})
	seen := map[string]bool{}
	pp := probePanel
	probePanel = func(p shared.WatchdogPeer) bool { return seen[p.ID] }
	t.Cleanup(func() { probePanel = pp })

	w, wc := fleetFixture("a", "b")
	w.panelQuiet(wc)
	w.panelLost = time.Now().Add(-2 * time.Hour)
	w.panelQuiet(wc)
	if n := f.notices(); len(n) != 0 {
		t.Fatalf("not asked for, yet sent %v", n)
	}

	wc.PanelQuietMin = 60
	w.panelLost = time.Now().Add(-30 * time.Minute)
	w.panelQuiet(wc)
	if n := f.notices(); len(n) != 0 {
		t.Fatalf("sent before the hour was up: %v", n)
	}

	// Another server still has its tunnel: the panel is fine, this
	// watcher's tunnel is not.
	w.panelLost = time.Now().Add(-61 * time.Minute)
	seen["b"] = true
	w.panelQuiet(wc)
	if n := f.notices(); len(n) != 0 {
		t.Fatalf("sent while b still reaches the panel: %v", n)
	}

	seen["b"] = false
	w.panelQuiet(wc)
	w.panelQuiet(wc)
	if n := f.notices(); !slices.Equal(n, []string{"[warning] Beacle panel is not answering"}) {
		t.Fatalf("want one notice, got %v", n)
	}

	w.panelBack()
	w.panelBack()
	if n := f.notices(); len(n) != 2 || n[1] != "[info] Beacle panel is back" {
		t.Fatalf("want one back notice, got %v", n)
	}
}

// A watcher cut off itself says nothing about the panel either, nor does a
// backup watcher while the primary is up.
func TestPanelQuietNotFromAWatcherCutOff(t *testing.T) {
	f := withFakeFleet(t, true, map[string]bool{"a": false, "b": false})
	pp := probePanel
	probePanel = func(shared.WatchdogPeer) bool { return false }
	t.Cleanup(func() { probePanel = pp })

	w, wc := fleetFixture("a", "b")
	wc.PanelQuietMin = 15
	w.probePeers(wc, true)
	w.panelLost = time.Now().Add(-time.Hour)
	w.panelQuiet(wc)
	if n := f.notices(); len(n) != 0 {
		t.Fatalf("a watcher that reaches nobody sent %v", n)
	}

	f.set(true, map[string]bool{"a": true, "b": true})
	w, wc = fleetFixture("a", "b")
	wc.PanelQuietMin, wc.Role, wc.PrimaryID = 15, "secondary", "a"
	w.panelLost = time.Now().Add(-time.Hour)
	w.panelQuiet(wc)
	if n := f.notices(); len(n) != 0 {
		t.Fatalf("the backup watcher sent %v while the primary is up", n)
	}
}
