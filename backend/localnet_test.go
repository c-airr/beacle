package main

import (
	"testing"
	"time"

	"beacle/shared"
)

// sweepFixture is an engine past its startup grace, with one server whose
// agent has been gone long enough to be reported, and a fake internet line.
func sweepFixture(t *testing.T, lineUp *bool) (*Store, *AlertEngine, string) {
	t.Helper()
	store, e := newStoreAndEngine(t)
	id := store.CreateVPS("white-panther", "white-panther", "100.64.0.7").VPS.ID
	store.UpdateVPS(id, func(en *VPSEntry) {
		en.VPS.Status = shared.VPSOnline
		en.VPS.LastSeen = time.Now().UTC().Add(-2 * shared.OfflineAfterSec * time.Second)
	})
	e.quietUntil = time.Time{}
	e.net.probe = func() bool { return *lineUp }
	// Answer "is the host there" from the cache, never from a real tailscale.
	e.reach[id] = reachProbe{up: false, at: time.Now()}
	return store, e, id
}

func openAlerts(store *Store) int {
	n := 0
	for _, a := range store.ListAlerts() {
		if !a.Resolved {
			n++
		}
	}
	return n
}

// The case this exists for: the lid was shut, or the cable pulled. Every
// server is out of reach because this computer is, and none of them is down.
func TestNoInternetHereRaisesNoOfflineAlert(t *testing.T) {
	up := false
	store, e, id := sweepFixture(t, &up)

	e.sweepOffline()

	if n := openAlerts(store); n != 0 {
		t.Fatalf("no internet on this computer raised %d alert(s)", n)
	}
	if e.LocalNetStatus().Online {
		t.Fatal("the panel should be told this computer is offline")
	}
	if st := store.GetVPS(id).VPS.Status; st != shared.VPSOffline {
		t.Fatalf("an unreachable server should still read offline, got %s", st)
	}
}

// With the line up, a missing agent is a real outage and is reported as before.
func TestMissingAgentWithInternetIsStillReported(t *testing.T) {
	up := true
	store, e, _ := sweepFixture(t, &up)

	e.sweepOffline()

	if n := openAlerts(store); n != 1 {
		t.Fatalf("expected the outage to be reported once, got %d alert(s)", n)
	}
}

// When the line comes back nothing has reconnected yet. Reporting right then
// would raise the very wall of alerts the outage was held back to avoid.
func TestInternetComingBackWaitsForAgents(t *testing.T) {
	up := false
	store, e, _ := sweepFixture(t, &up)
	e.sweepOffline()

	up = true
	e.sweepOffline()

	if n := openAlerts(store); n != 0 {
		t.Fatalf("the internet coming back raised %d alert(s) before agents could reconnect", n)
	}
	if !e.LocalNetStatus().Online {
		t.Fatal("the banner should go once the internet is back")
	}
	if !time.Now().Before(e.quietUntil) {
		t.Fatal("alerts should be held while agents reconnect")
	}

	// A server that still has not come back once the wait is over is down.
	e.quietUntil = time.Time{}
	e.sweepOffline()
	if n := openAlerts(store); n != 1 {
		t.Fatalf("a server still gone after the wait should be reported, got %d alert(s)", n)
	}
}

func TestGoodAnswerIsReusedButABadOneIsNot(t *testing.T) {
	calls := 0
	up := true
	n := NewLocalNet()
	n.probe = func() bool { calls++; return up }

	n.Up(time.Minute)
	n.Up(time.Minute)
	if calls != 1 {
		t.Fatalf("a fresh good answer should be reused, probed %d times", calls)
	}

	up = false
	n.Check()
	n.Up(time.Minute)
	n.Up(time.Minute)
	if calls != 4 {
		t.Fatalf("a bad answer should be asked again every time, probed %d times", calls)
	}
}

func TestLineChangesAreAnnouncedOnce(t *testing.T) {
	up := true
	n := NewLocalNet()
	n.probe = func() bool { return up }
	var got []bool
	n.onChange = func(st shared.LocalNetStatus) { got = append(got, st.Online) }

	n.Check()
	up = false
	n.Check()
	n.Check()
	up = true
	n.Check()

	if len(got) != 2 || got[0] || !got[1] {
		t.Fatalf("expected one announcement per flip (down, up), got %v", got)
	}
}

// The wait after a local outage must outlast a reconnect over a tunnel that
// is itself coming back, and stay shorter than a minute so a server that
// really died meanwhile is still reported promptly.
func TestLocalOutageGraceIsBounded(t *testing.T) {
	if localOutageGrace < agentReconnectGrace {
		t.Fatalf("grace after a local outage (%v) is shorter than at startup (%v)",
			localOutageGrace, agentReconnectGrace)
	}
	if localOutageGrace > time.Minute {
		t.Fatalf("grace after a local outage (%v) delays real outages too long", localOutageGrace)
	}
	if netUpRecheck >= shared.OfflineAfterSec*time.Second {
		t.Fatalf("a good line answer kept %v could predate the outage it excuses", netUpRecheck)
	}
}
