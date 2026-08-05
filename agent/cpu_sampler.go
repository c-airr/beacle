package main

import "time"

// CPU usage is a rate, not a reading: it only exists as the change in
// /proc/stat counters between two moments. That makes it fragile in a way a
// plain gauge is not — how far apart those moments are decides whether the
// answer means anything.
//
// The counters advance in jiffies, 10ms each. Sample twice a few milliseconds
// apart on an idle box and most cores show no change at all, while any core
// that happened to tick one non-idle jiffy reads as 100% busy. That is not a
// spike; it is a measurement taken over a window too short to hold one.
//
// It happened constantly, because the metrics push is triggered both on a
// timer and by RequestRefresh after every panel action — so any click could
// land a second sample right next to the first, and the panel would show a
// four-core server pinned at 100% while its load average sat at 0.41.
//
// cpuSampler refuses to answer from a window that short and repeats its last
// real measurement instead.
//
// Metrics no longer drives sampling at all — see cpu_monitor_linux.go. The
// guard here still matters for the monitor's own ticker (and for tests), and
// documents the failure mode the panel kept showing: load 0.06 with one core
// at 95%.
type cpuSampler struct {
	prevIdle  uint64
	prevTotal uint64
	// hasPrev distinguishes "no reading yet" from a genuine zero, so the first
	// sample reports 0% instead of comparing against an empty counter.
	hasPrev bool

	last   float64
	lastAt time.Time
}

// minCPUWindow is the shortest gap that can carry a meaningful answer. Well
// above one jiffy, comfortably below the fastest collection interval (3s), so
// scheduled samples are never rejected and back-to-back ones always are.
const minCPUWindow = 700 * time.Millisecond

// sample folds in a new counter reading and returns the usage percentage.
func (s *cpuSampler) sample(idle, total uint64, now time.Time) float64 {
	if !s.lastAt.IsZero() && now.Sub(s.lastAt) < minCPUWindow {
		// Too soon to mean anything. The counters are deliberately left alone:
		// consuming them here would shorten the next window too.
		return s.last
	}

	pct := 0.0
	if s.hasPrev {
		pct = deltaPercent(s.prevIdle, s.prevTotal, idle, total)
	}
	s.prevIdle, s.prevTotal, s.hasPrev = idle, total, true
	s.last, s.lastAt = pct, now
	return pct
}

// deltaPercent turns two counter readings into a percentage, refusing anything
// that cannot be one.
func deltaPercent(prevIdle, prevTotal, idle, total uint64) float64 {
	// Counters only go up. Going backwards means a reboot, a CPU coming online,
	// or a rollover — none of which is a usage figure.
	if total <= prevTotal || idle < prevIdle {
		return 0
	}
	dTotal := float64(total - prevTotal)
	dIdle := float64(idle - prevIdle)
	if dTotal <= 0 {
		return 0
	}
	pct := (1 - dIdle/dTotal) * 100
	if pct < 0 {
		return 0
	}
	if pct > 100 {
		return 100
	}
	return pct
}

// multiSampler is the same guard for a set of cores, which have to move
// together: rejecting a short window for one core and accepting it for
// another would report cores measured over different spans side by side.
type multiSampler struct {
	cores  []cpuSampler
	last   []float64
	lastAt time.Time
}

func (m *multiSampler) sample(idle, total []uint64, now time.Time) []float64 {
	if len(idle) == 0 || len(idle) != len(total) {
		return nil
	}
	if !m.lastAt.IsZero() && now.Sub(m.lastAt) < minCPUWindow && len(m.last) == len(idle) {
		return m.last
	}
	// A different core count means the previous readings describe a different
	// machine shape; start over rather than compare across it.
	if len(m.cores) != len(idle) {
		m.cores = make([]cpuSampler, len(idle))
	}

	out := make([]float64, len(idle))
	for i := range idle {
		// now is passed through unchanged so the per-core guards never trip on
		// their own; this sampler already decided the window is wide enough.
		c := &m.cores[i]
		c.lastAt = time.Time{}
		out[i] = c.sample(idle[i], total[i], now)
	}
	m.last, m.lastAt = out, now
	return out
}
