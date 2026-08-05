package main

import (
	"testing"
	"time"
)

func TestStretchLeavesCheapStagesAlone(t *testing.T) {
	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{"metrics": {LastMs: 0.8}}
	selfStat.mu.Unlock()

	base := 3 * time.Second
	if got := stretchExpensive(base, "metrics"); got != base {
		t.Errorf("got %s, want %s — a sub-millisecond stage must not be stretched", got, base)
	}
}

func TestStretchSlowsExpensiveSystemd(t *testing.T) {
	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{"systemd": {LastMs: 1792.4}}
	selfStat.mu.Unlock()

	// Active mode asks for 30s; a 1.8s systemctl read has to be pulled back.
	got := stretchExpensive(30*time.Second, "systemd")
	if got < time.Minute {
		t.Errorf("got %s, want at least 1m — this is the poll that pinned a core", got)
	}
}
