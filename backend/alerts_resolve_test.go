package main

import (
	"testing"

	"beacle/shared"
)

func newStoreAndEngine(t *testing.T) (*Store, *AlertEngine) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	return store, NewAlertEngine(store, NewHub())
}

var testVPS = shared.VPS{ID: "vps1", Name: "white-panther"}

// A condition that stops holding should stop being listed. Clearing used to
// only forget the active flag, so an alert raised by five seconds of lost
// connectivity stayed open in the panel indefinitely, long after the agent was
// back.
func TestClearingAConditionResolvesItsAlert(t *testing.T) {
	store, e := newStoreAndEngine(t)

	e.fire(testVPS, shared.AlertAgentOffline, shared.SeverityCritical, "", "VPS offline")
	open := 0
	for _, a := range store.ListAlerts() {
		if !a.Resolved {
			open++
		}
	}
	if open != 1 {
		t.Fatalf("expected one open alert, got %d", open)
	}

	e.clear(testVPS.ID, shared.AlertAgentOffline, "")

	for _, a := range store.ListAlerts() {
		if !a.Resolved {
			t.Errorf("alert %s (%s) is still open after the condition cleared", a.ID, a.Type)
		}
	}
}

// Two containers down, one recovers: the other one's alert has to stay open.
// This is why alerts carry the key the engine keys them by.
func TestClearingOneKeyLeavesTheOthersAlone(t *testing.T) {
	store, e := newStoreAndEngine(t)

	e.fire(testVPS, shared.AlertDockerCrash, shared.SeverityCritical, "container-a", "a crashed")
	e.fire(testVPS, shared.AlertDockerCrash, shared.SeverityCritical, "container-b", "b crashed")

	e.clear(testVPS.ID, shared.AlertDockerCrash, "container-a")

	for _, a := range store.ListAlerts() {
		switch a.Key {
		case "container-a":
			if !a.Resolved {
				t.Error("container-a recovered but its alert is still open")
			}
		case "container-b":
			if a.Resolved {
				t.Error("container-b is still down but its alert was resolved")
			}
		}
	}
}

// Alerts outlive the process that raised them. A restarted backend has to
// adopt the open ones, or it neither resolves them later nor recognises the
// condition as already reported — and raises a second alert beside the first.
func TestRestartAdoptsOpenAlerts(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatalf("store: %v", err)
	}
	e := NewAlertEngine(store, NewHub())
	e.fire(testVPS, shared.AlertAgentOffline, shared.SeverityCritical, "", "VPS offline")

	// Same data directory, fresh process.
	restarted, err := NewStore(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	e2 := NewAlertEngine(restarted, NewHub())

	e2.fire(testVPS, shared.AlertAgentOffline, shared.SeverityCritical, "", "VPS offline")
	if n := len(restarted.ListAlerts()); n != 1 {
		t.Errorf("got %d alerts after a restart, want 1 — the open one was not adopted", n)
	}

	e2.clear(testVPS.ID, shared.AlertAgentOffline, "")
	for _, a := range restarted.ListAlerts() {
		if !a.Resolved {
			t.Error("an alert raised before the restart was never resolved")
		}
	}
}
