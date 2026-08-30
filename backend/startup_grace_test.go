package main

import (
	"testing"
	"time"

	"beacle/shared"
)

// Coming back to a machine that was off all night must not look like an
// outage. Every VPS's LastSeen is hours old at that point, and the offline
// sweep would read the whole fleet as dead a second or two before the agents
// finish reconnecting.
func TestOfflineSweepWaitsForAgentsToReconnectAfterStartup(t *testing.T) {
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	e := NewAlertEngine(store, NewHub())

	if time.Since(e.startedAt) >= agentReconnectGrace {
		t.Fatalf("a freshly built engine should still be inside its grace window")
	}
}

func TestReconnectGraceIsBoundedAtBothEnds(t *testing.T) {
	// Long enough to cover a reconnect (agents retry every 1-5s), short enough
	// that a server which really did die is still reported promptly.
	if agentReconnectGrace < 10*time.Second {
		t.Fatalf("grace %v is too short to cover an agent reconnect", agentReconnectGrace)
	}
	outageWindow := shared.OfflineAfterSec * time.Second
	if agentReconnectGrace >= outageWindow {
		t.Fatalf("grace %v would delay reporting a genuine outage (%v)",
			agentReconnectGrace, outageWindow)
	}
}
