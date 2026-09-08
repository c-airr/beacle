package main

import "sort"

// Deciding when a machine is doing something unusual *for itself*.
//
// A fixed threshold is the obvious approach and the wrong one. A box that idles
// at 5% and jumps to 30% has done something worth recording; a build server
// that lives at 60% has not, and would trip a 50% rule every minute of its
// working life. What matters is the departure from what this machine normally
// does, which only the machine itself can know.
//
// So the baseline is learned: a rolling window of recent readings, summarised
// by its median. The median rather than the mean because one spike must not
// drag the baseline up behind it — the very thing being measured would then
// hide the next one.

// spikeWindow is how many readings the baseline is drawn from. At a reading a
// minute this is the last half hour: long enough that a brief burst does not
// become "normal", short enough to follow a machine whose load genuinely
// changes through the day.
const spikeWindow = 30

// spikeMinSamples is how much history is needed before any judgement is made.
// A freshly started agent has no idea what normal looks like, and guessing
// would file its first busy minute as an anomaly.
const spikeMinSamples = 10

// Thresholds for calling a reading a spike. Both must be cleared: the ratio
// alone would fire on 0.2% -> 1%, which is arithmetically a fivefold rise and
// practically nothing at all.
const (
	// How many times the baseline a reading must reach.
	spikeRatio = 2.0
	// And how many percentage points above it, so noise near zero is ignored.
	spikeAbsolute = 15.0
)

// There is deliberately no "record anything above N%" rule. It reads as a
// safety net and is not one: a machine that genuinely runs at 95% would trip it
// every minute forever, burying the readings that mean something under the ones
// that do not. A server pinned at 95% is a matter for the alert thresholds,
// which exist and say so out loud — this file answers a narrower question,
// which is what changed and when.

// spikeTracker watches one metric and reports when a reading departs from what
// that metric has recently been doing.
type spikeTracker struct {
	recent []float64
	// Set while a spike is in progress, so a burst lasting ten minutes is one
	// event and not ten. Cleared when the reading comes back to normal.
	firing bool
}

// observe records a reading and reports whether it starts a spike.
//
// Returns true only on the reading that *begins* one. A sustained spike keeps
// returning false until it ends, because the interesting moment is the onset —
// that is when the cause is still visible in the process list.
func (t *spikeTracker) observe(v float64) bool {
	base, ok := t.baseline()
	spike := ok && aboveBaseline(v, base)

	// A spiking reading is withheld from the baseline. Letting a burst in is
	// how a tracker learns that 100% is unremarkable and stops reporting
	// exactly when it matters most. Everything else joins the window, so a
	// machine whose load genuinely changes is followed rather than argued with.
	if !ok || !aboveBaseline(v, base) {
		t.recent = append(t.recent, v)
		if len(t.recent) > spikeWindow {
			t.recent = t.recent[len(t.recent)-spikeWindow:]
		}
	}

	if !spike {
		t.firing = false
		return false
	}
	if t.firing {
		return false // already recorded the onset of this one
	}
	t.firing = true
	return true
}

// baseline is the median of the window, and whether there is enough of one to
// trust. The median ignores the outliers it is meant to be measured against.
func (t *spikeTracker) baseline() (float64, bool) {
	if len(t.recent) < spikeMinSamples {
		return 0, false
	}
	sorted := append([]float64(nil), t.recent...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid], true
	}
	return (sorted[mid-1] + sorted[mid]) / 2, true
}

// aboveBaseline is the whole test: a real departure from what this machine has
// been doing, by both a multiple and a margin. The multiple alone would fire on
// 0.2% -> 1%; the margin alone would fire on any busy server that drifted
// fifteen points.
func aboveBaseline(v, base float64) bool {
	return v >= base*spikeRatio && v >= base+spikeAbsolute
}
