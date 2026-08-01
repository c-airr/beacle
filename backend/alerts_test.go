package main

import (
	"testing"
	"time"

	"beacle/shared"
)

func newTestEngine() *AlertEngine {
	return &AlertEngine{
		active:         map[string]bool{},
		since:          map[string]time.Time{},
		prevContainers: map[string]map[string]shared.ContainerInfo{},
		prevServices:   map[string]map[string]string{},
	}
}

func TestSustainedIgnoresASingleSpike(t *testing.T) {
	e := newTestEngine()

	// One sample at 100% is a build or a container start, not an incident.
	if e.sustained("vps1", "cpu", true) {
		t.Fatal("first sample over the threshold must only start the clock")
	}
	// Back under the threshold before the window elapses — clock resets.
	if e.sustained("vps1", "cpu", false) {
		t.Fatal("a sample under the threshold must never fire")
	}
	if e.sustained("vps1", "cpu", true) {
		t.Fatal("after dropping under, the window must start over")
	}
}

func TestSustainedFiresOnlyAfterTheFullWindow(t *testing.T) {
	e := newTestEngine()
	e.sustained("vps1", "cpu", true)

	// Just short of the window.
	e.since["vps1|cpu"] = time.Now().Add(-(shared.SustainedSeconds - 1) * time.Second)
	if e.sustained("vps1", "cpu", true) {
		t.Error("fired before the sustained window elapsed")
	}

	// Past the window.
	e.since["vps1|cpu"] = time.Now().Add(-(shared.SustainedSeconds + 1) * time.Second)
	if !e.sustained("vps1", "cpu", true) {
		t.Error("did not fire after the sustained window elapsed")
	}
}

func TestSustainedTracksMetricsAndHostsSeparately(t *testing.T) {
	e := newTestEngine()
	e.sustained("vps1", "cpu", true)
	e.since["vps1|cpu"] = time.Now().Add(-(shared.SustainedSeconds + 1) * time.Second)

	if !e.sustained("vps1", "cpu", true) {
		t.Error("cpu on vps1 should be sustained")
	}
	// Same host, different metric: independent clock.
	if e.sustained("vps1", "mem", true) {
		t.Error("mem must not inherit the cpu clock")
	}
	// Same metric, different host: independent clock.
	if e.sustained("vps2", "cpu", true) {
		t.Error("vps2 must not inherit vps1's clock")
	}
}

func TestSustainedRecoveryClearsTheClock(t *testing.T) {
	e := newTestEngine()
	e.sustained("vps1", "cpu", true)
	e.since["vps1|cpu"] = time.Now().Add(-(shared.SustainedSeconds + 5) * time.Second)
	if !e.sustained("vps1", "cpu", true) {
		t.Fatal("expected the condition to be sustained")
	}

	// Load drops: the stored start time must go, so a later spike waits out a
	// fresh window instead of firing immediately.
	e.sustained("vps1", "cpu", false)
	if _, ok := e.since["vps1|cpu"]; ok {
		t.Error("recovery must forget when the threshold was first crossed")
	}
	if e.sustained("vps1", "cpu", true) {
		t.Error("a spike after recovery must start a new window")
	}
}
