package main

import "testing"

// settle feeds a steady reading until the tracker has a baseline.
func settle(t *spikeTracker, v float64, n int) {
	for i := 0; i < n; i++ {
		t.observe(v)
	}
}

func TestAJumpFromIdleIsASpikeEvenThoughThirtyPercentIsLow(t *testing.T) {
	// The case this exists for: a machine that sits at 5-10% overnight and
	// jumps to 30%. No fixed threshold would catch that without also firing
	// constantly on a server that is simply busy.
	tr := &spikeTracker{}
	settle(tr, 8, 15)
	if !tr.observe(30) {
		t.Fatal("a jump from 8% to 30% should be recorded")
	}
}

func TestASteadilyBusyServerIsNotSpiking(t *testing.T) {
	// The mirror image: 60% all day is this machine's normal, and recording it
	// every minute would bury the one reading that matters.
	tr := &spikeTracker{}
	settle(tr, 60, 15)
	for _, v := range []float64{58, 62, 61, 59, 63} {
		if tr.observe(v) {
			t.Fatalf("%v%% is normal for this machine and must not be a spike", v)
		}
	}
}

func TestNoiseNearZeroIsNotASpike(t *testing.T) {
	// 0.2% -> 1% is a fivefold rise and means nothing. The absolute floor is
	// what stops an idle machine reporting constantly.
	tr := &spikeTracker{}
	settle(tr, 0.2, 15)
	if tr.observe(1) {
		t.Fatal("a rise from 0.2% to 1% is noise, not a spike")
	}
	if tr.observe(4) {
		t.Fatal("4% on an idle machine is still not worth a record")
	}
}

func TestNothingIsJudgedBeforeThereIsABaseline(t *testing.T) {
	// A just-started agent does not know what normal is. Guessing would file
	// its first busy minute as an anomaly.
	tr := &spikeTracker{}
	for i := 0; i < spikeMinSamples-1; i++ {
		if tr.observe(95) {
			t.Fatal("no spike may be reported before a baseline exists")
		}
	}
}

func TestASustainedBurstIsOneEventNotMany(t *testing.T) {
	// Ten minutes at 100% is one thing that happened. Recording the process
	// list every minute of it would be ten near-identical snapshots.
	tr := &spikeTracker{}
	settle(tr, 5, 15)
	if !tr.observe(95) {
		t.Fatal("the onset should be recorded")
	}
	for i := 0; i < 10; i++ {
		if tr.observe(97) {
			t.Fatal("a burst already being recorded must not fire again")
		}
	}
}

func TestANewBurstAfterRecoveryIsRecordedAgain(t *testing.T) {
	// Two separate incidents are two records, however close together.
	tr := &spikeTracker{}
	settle(tr, 5, 15)
	if !tr.observe(95) {
		t.Fatal("first burst should fire")
	}
	settle(tr, 5, 3) // back to normal
	if !tr.observe(95) {
		t.Fatal("a second burst after recovery should fire again")
	}
}

func TestALongBurstDoesNotBecomeTheNewNormal(t *testing.T) {
	// The trap this design exists to avoid: if spiking readings joined the
	// baseline, a machine pinned at 100% would eventually decide that 100% is
	// unremarkable and stop reporting — exactly when it matters most.
	tr := &spikeTracker{}
	settle(tr, 5, 15)
	tr.observe(100)
	for i := 0; i < 60; i++ {
		tr.observe(100) // an hour of it
	}
	base, ok := tr.baseline()
	if !ok || base > 10 {
		t.Fatalf("baseline drifted to %v; an hour at 100%% must not become normal", base)
	}
}

func TestAPinnedMachineIsItsOwnNormal(t *testing.T) {
	// A machine that has always run at 95% is not spiking by staying there.
	// Recording it every minute would bury the readings that mean something
	// under thousands that do not; that a server sits at 95% is a matter for
	// the alert thresholds, not for this.
	tr := &spikeTracker{}
	settle(tr, 95, 15)
	if tr.observe(96) {
		t.Fatal("staying at its usual load is not a spike")
	}
}

func TestTheBaselineFollowsAGenuineChangeInLoad(t *testing.T) {
	// A machine that quietens down should have a lower bar afterwards, not
	// keep measuring against a busy afternoon.
	tr := &spikeTracker{}
	settle(tr, 50, 40)
	settle(tr, 5, 40)
	base, ok := tr.baseline()
	if !ok || base > 10 {
		t.Fatalf("baseline should have followed the drop, got %v", base)
	}
	if !tr.observe(30) {
		t.Fatal("30%% is a spike once the machine has settled at 5%%")
	}
}
