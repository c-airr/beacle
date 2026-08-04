package main

import (
	"math"
	"testing"
	"time"
)

func closeTo(got, want float64) bool { return math.Abs(got-want) < 0.001 }

// The bug this exists to prevent: the panel showed a four-core server at
// 100.0% overall, cpu0 and cpu3 pinned, cpu1 and cpu2 flat — while its load
// average read 0.41 and htop showed 98% idle.
//
// Nothing was busy. Two samples landed milliseconds apart (the metrics push
// runs on a timer *and* on RequestRefresh after any panel action), and over a
// window that short the jiffy counters barely move: cores that ticked one
// non-idle jiffy divide out to 100%, the rest to 0%.
func TestBackToBackSamplesDoNotInventLoad(t *testing.T) {
	var s cpuSampler
	start := time.Now()

	// A quiet first window, the way an idle box actually looks: nearly all of
	// the jiffies went to idle, so this is a few percent busy.
	s.sample(1000, 1100, start)
	measured := s.sample(1990, 2100, start.Add(3*time.Second))

	// Now the pathological case: eight milliseconds later, two more jiffies
	// have passed and neither was idle. Computed naively that is
	// (1 - 0/2) * 100 = 100%.
	got := s.sample(1990, 2102, start.Add(3*time.Second+8*time.Millisecond))

	if got == 100 {
		t.Fatal("an 8ms window reported 100% — this is the bug that put an idle server at full load")
	}
	if got != measured {
		t.Errorf("got %.1f, want the last real measurement %.1f", got, measured)
	}
}

// Samples spaced the way the collector actually schedules them must be
// measured, not skipped — the guard has to reject only the useless windows.
func TestScheduledSamplesAreMeasured(t *testing.T) {
	var s cpuSampler
	now := time.Now()

	s.sample(0, 0, now)
	// Half the jiffies idle over the window: 50% busy.
	now = now.Add(3 * time.Second)
	if got := s.sample(500, 1000, now); got != 50 {
		t.Errorf("got %.1f%%, want 50%% — a normal 3s window was not measured", got)
	}
	now = now.Add(3 * time.Second)
	if got := s.sample(1000, 2000, now); got != 50 {
		t.Errorf("got %.1f%%, want 50%% on the second window", got)
	}
}

// A rejected sample must not consume the counters either: doing so would make
// the *next* window start from a reading nobody measured against, quietly
// halving it.
func TestRejectedSampleDoesNotEatTheWindow(t *testing.T) {
	var s cpuSampler
	now := time.Now()

	s.sample(0, 0, now)
	now = now.Add(3 * time.Second)
	s.sample(500, 1000, now) // 50%

	// Rejected: too soon.
	s.sample(600, 1200, now.Add(10*time.Millisecond))

	// A full window later, measured from the 500/1000 reading: 1000 idle of
	// 2000 total is still 50%.
	if got := s.sample(1500, 3000, now.Add(3*time.Second)); got != 50 {
		t.Errorf("got %.1f%%, want 50%% — the rejected sample corrupted the next window", got)
	}
}

// Counters that go backwards mean a reboot or a core coming online, not usage.
func TestCountersGoingBackwardsReportZero(t *testing.T) {
	if got := deltaPercent(500, 1000, 400, 900); got != 0 {
		t.Errorf("got %.1f, want 0 for counters that went backwards", got)
	}
	if got := deltaPercent(500, 1000, 600, 1000); got != 0 {
		t.Errorf("got %.1f, want 0 when total did not advance", got)
	}
}

// Cores have to be measured over the same window as each other, or the panel
// shows figures from different spans side by side.
func TestCoresMoveTogether(t *testing.T) {
	var m multiSampler
	now := time.Now()

	m.sample([]uint64{0, 0}, []uint64{0, 0}, now)
	now = now.Add(3 * time.Second)
	first := m.sample([]uint64{500, 900}, []uint64{1000, 1000}, now)
	// Compared with a tolerance: these are ratios of integers, so 10% arrives
	// as 9.999999999999998 and an exact match would fail for no useful reason.
	if len(first) != 2 || !closeTo(first[0], 50) || !closeTo(first[1], 10) {
		t.Fatalf("got %v, want [50 10]", first)
	}

	// One jiffy later — the whole set is repeated, not recomputed per core.
	again := m.sample([]uint64{500, 901}, []uint64{1002, 1002}, now.Add(9*time.Millisecond))
	if len(again) != 2 || again[0] != first[0] || again[1] != first[1] {
		t.Errorf("got %v, want the previous reading %v", again, first)
	}
}

// A machine that gains or loses a core starts over rather than comparing
// against readings that describe a different shape.
func TestCoreCountChangeStartsOver(t *testing.T) {
	var m multiSampler
	now := time.Now()

	m.sample([]uint64{0, 0}, []uint64{0, 0}, now)
	now = now.Add(3 * time.Second)
	m.sample([]uint64{500, 500}, []uint64{1000, 1000}, now)

	now = now.Add(3 * time.Second)
	got := m.sample([]uint64{500, 500, 500}, []uint64{1000, 1000, 1000}, now)
	if len(got) != 3 {
		t.Fatalf("got %d cores, want 3", len(got))
	}
	for i, v := range got {
		if v != 0 {
			t.Errorf("core %d reported %.1f%% on its first reading, want 0", i, v)
		}
	}
}
