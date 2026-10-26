package main

import (
	"testing"
	"time"

	"beacle/shared"
)

// fleetSweepFixture is sweepFixture with three servers, all gone long enough
// to be reported, and an agent hub whose sockets the test opens by hand.
func fleetSweepFixture(t *testing.T) (*Store, *AlertEngine, []string) {
	t.Helper()
	store, e := newStoreAndEngine(t)
	e.agentHub = &AgentHub{agents: map[string]*agentSession{}}
	var ids []string
	for i, name := range []string{"fra", "waw", "nyc"} {
		id := store.CreateVPS(name, name, "100.64.0."+string(rune('2'+i))).VPS.ID
		store.UpdateVPS(id, func(en *VPSEntry) {
			en.VPS.Status = shared.VPSOnline
			en.VPS.LastSeen = time.Now().UTC().Add(-2 * shared.OfflineAfterSec * time.Second)
		})
		e.reach[id] = reachProbe{up: false, at: time.Now()}
		ids = append(ids, id)
	}
	e.quietUntil = time.Time{}
	e.net.probe = func() bool { return true }
	return store, e, ids
}

func connect(e *AlertEngine, id string) {
	s := &agentSession{vpsID: id, done: make(chan struct{})}
	s.registered.Store(true)
	e.agentHub.agents[id] = s
	e.store.UpdateVPS(id, func(en *VPSEntry) { en.VPS.LastSeen = time.Now().UTC() })
}

// The internet is up but not one server answers: this computer's Tailscale
// is off or still finding its way back after the line returned. A whole
// fleet dying in the same three seconds is not what happened.
func TestEveryServerGoneAtOnceIsThisComputersTailnet(t *testing.T) {
	store, e, ids := fleetSweepFixture(t)
	e.sweepOffline()
	if n := openAlerts(store); n != 0 {
		t.Fatalf("all %d servers silent at once raised %d alert(s)", len(ids), n)
	}
	if st := store.GetVPS(ids[0]).VPS.Status; st != shared.VPSOffline {
		t.Fatalf("an unreachable server should still read offline, got %s", st)
	}
}

// Tailscale finds the peers one by one. The first server back is no reason
// to report the others before they had the same grace.
func TestFirstServerBackGivesTheRestTheirGrace(t *testing.T) {
	store, e, ids := fleetSweepFixture(t)
	e.sweepOffline()
	connect(e, ids[0])
	e.sweepOffline()
	if n := openAlerts(store); n != 0 {
		t.Fatalf("the first server back raised %d alert(s) for the rest", n)
	}
	if !time.Now().Before(e.quietUntil) {
		t.Fatal("alerts should be held while the rest reconnect")
	}

	// One still gone once the wait is over is down.
	connect(e, ids[1])
	e.quietUntil = time.Time{}
	e.sweepOffline()
	if n := openAlerts(store); n != 1 {
		t.Fatalf("a server still gone after the wait should be reported, got %d alert(s)", n)
	}
}

// The guard is about all of them: one server gone while the rest answer is
// an outage.
func TestOneServerGoneIsStillReported(t *testing.T) {
	store, e, ids := fleetSweepFixture(t)
	connect(e, ids[0])
	connect(e, ids[1])
	e.sweepOffline()
	if n := openAlerts(store); n != 1 {
		t.Fatalf("expected one alert, got %d", n)
	}
}
