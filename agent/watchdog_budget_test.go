package main

import "testing"

// The watchdog collects whatever it wants to watch for changes, so watching
// something expensive at 5s intervals silently overrides whatever interval
// power mode chose for it.
//
// That is what happened: eco mode asks for systemd every 60s, the watchdog
// collected it every 5s regardless, and on a host where the D-Bus path had
// fallen back to spawning systemctl each collection cost ~2s. Roughly 400
// collections in 45 minutes against the ~46 the interval called for.
func TestWatchdogSkipsStagesItCannotAfford(t *testing.T) {
	budget := float64(5000) * watchdogCostShare
	if budget != 250 {
		t.Fatalf("budget = %.0fms, expected 250ms for a 5s interval", budget)
	}

	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{
		"metrics": {LastMs: 0.6},
		"ports":   {LastMs: 11.7},
		"proxy":   {LastMs: 4.2},
		"docker":  {LastMs: 188.0}, // measured with one-shot stats — still too heavy
		"systemd": {LastMs: 1792.4}, // systemctl fallback
	}
	selfStat.mu.Unlock()

	for _, stage := range []string{"metrics", "ports", "proxy"} {
		if !affordable(stage, budget) {
			t.Errorf("%s costs %.1fms and was skipped — cheap stages must stay watched",
				stage, lastStageMs(stage))
		}
	}
	for _, stage := range []string{"docker", "systemd"} {
		if affordable(stage, budget) {
			t.Errorf("%s costs %.0fms against a %.0fms budget and was still polled — "+
				"this is the loop that pinned the CPU", stage, lastStageMs(stage), budget)
		}
	}
}

func TestDockerNeverOnWatchdog(t *testing.T) {
	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{"docker": {LastMs: 40}} // under budget, still banned
	selfStat.mu.Unlock()

	if affordable("docker", 250) {
		t.Error("docker was allowed on the watchdog — it must not be, regardless of cost")
	}
}

// The same stage can be cheap or expensive depending on the host, so the
// decision has to come from measurement rather than a hardcoded list. A
// D-Bus systemd read is milliseconds and belongs in the watchdog.
func TestCheapSystemdStaysWatched(t *testing.T) {
	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{"systemd": {LastMs: 35}}
	selfStat.mu.Unlock()

	if !affordable("systemd", 250) {
		t.Error("a 35ms systemd read was skipped; only the expensive path should be")
	}
}

// A stage nobody has timed yet gets one run, which is how it becomes measured.
// Docker is the exception — it is never invited onto the watchdog.
func TestUnmeasuredStageIsAllowedOnce(t *testing.T) {
	selfStat.mu.Lock()
	selfStat.stages = map[string]*stageStat{}
	selfStat.mu.Unlock()

	if !affordable("systemd", 250) {
		t.Error("an unmeasured stage was skipped, so it could never be measured")
	}
	if affordable("docker", 250) {
		t.Error("unmeasured docker was allowed on the watchdog")
	}
}
