package main

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// What this prevents, seen on a real VPS six seconds after the agent started:
//
//	CGroup: /system.slice/beacle-agent.service
//	        ├─1453846 /opt/beacle-agent/beacle-agent
//	        ├─1453897 systemctl show --property=Id --property=MainPID ...
//	        ├─1453899 systemctl show --property=Id --property=MainPID ...
//	        └─1453903 systemctl show --property=Id --property=MainPID ...
//
// Three collections of the same data at once, each forking its own systemctl
// and slowing the others down — which is how a systemd read that normally took
// two seconds was measured at fifteen.
//
// The watchdog's cost budget cannot catch this: it reads the last measured
// cost, and at startup nothing has been measured yet, so every caller sees zero
// and proceeds.
func TestSimultaneousCallersCollectOnce(t *testing.T) {
	g := newCollectGate[int](0) // no freshness window: isolate the locking
	var collections atomic.Int32
	release := make(chan struct{})

	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			g.do(func() int {
				collections.Add(1)
				<-release // hold the collection open so the others pile up
				return 42
			})
		}()
	}

	// Give all three time to arrive at the gate before any can finish.
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()

	if got := collections.Load(); got != 1 {
		t.Errorf("%d concurrent collections ran, want 1 — this is the three systemctl processes", got)
	}
}

// Callers that queued behind a collection must receive its result, not a zero
// value or a second collection's.
func TestQueuedCallersGetTheResult(t *testing.T) {
	g := newCollectGate[int](time.Minute)
	release := make(chan struct{})
	results := make(chan int, 3)

	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- g.do(func() int {
				<-release
				return 7
			})
		}()
	}

	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	close(results)

	for v := range results {
		if v != 7 {
			t.Errorf("a queued caller got %d, want 7", v)
		}
	}
}

// A value inside the freshness window is reused rather than gathered again.
func TestFreshValueIsReused(t *testing.T) {
	g := newCollectGate[int](time.Minute)
	var collections atomic.Int32

	collect := func() int {
		collections.Add(1)
		return int(collections.Load())
	}

	first := g.do(collect)
	second := g.do(collect)

	if collections.Load() != 1 {
		t.Errorf("collected %d times, want 1 — a warm value was ignored", collections.Load())
	}
	if first != second {
		t.Errorf("got %d then %d; the cached value should have been returned", first, second)
	}
}

// Once the window passes, a real collection happens again — a gate that never
// refreshed would freeze the panel on its first reading.
func TestStaleValueIsCollectedAgain(t *testing.T) {
	g := newCollectGate[int](20 * time.Millisecond)
	var collections atomic.Int32

	collect := func() int {
		collections.Add(1)
		return int(collections.Load())
	}

	g.do(collect)
	time.Sleep(40 * time.Millisecond)
	g.do(collect)

	if collections.Load() != 2 {
		t.Errorf("collected %d times, want 2 — the value went stale and was not refreshed",
			collections.Load())
	}
}
