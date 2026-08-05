package main

import (
	"sync"
	"time"
)

// collectGate makes sure one kind of collection runs at a time, and that a
// result which is still warm is reused instead of gathered again.
//
// Three things ask for the same data independently: the interval loop for that
// stage, PushAll (fired by RequestRefresh after any panel action, and on power
// mode changes), and the watchdog. Nothing coordinated them, so on a busy
// moment three collections of the same subsystem ran side by side — visible on
// the VPS as three concurrent `systemctl show` processes six seconds after the
// agent started, each forking its own and slowing the others down. That is how
// a systemd read that normally takes two seconds ended up taking fifteen.
//
// The cost budget in the watchdog does not help here: it reads the last
// measured cost, and at startup nothing has been measured, so every caller sees
// zero and goes ahead.
//
// Callers that arrive while a collection is in flight wait for it and take its
// result, rather than starting a second one — waiting is the point, since the
// answer they wanted is already being fetched.
type collectGate[T any] struct {
	mu      sync.Mutex
	running bool
	done    chan struct{} // closed when the in-flight collection finishes

	value  T
	at     time.Time
	freshS time.Duration
}

func newCollectGate[T any](fresh time.Duration) *collectGate[T] {
	return &collectGate[T]{freshS: fresh}
}

// do returns a recent value, joins a collection already under way, or performs
// one. collect is never called concurrently with itself.
func (g *collectGate[T]) do(collect func() T) T {
	g.mu.Lock()

	// Warm enough to reuse. Collecting the same thing twice within a window
	// this short cannot tell anyone anything new.
	if !g.at.IsZero() && time.Since(g.at) < g.freshS {
		v := g.value
		g.mu.Unlock()
		return v
	}

	if g.running {
		// Someone else is already fetching exactly this. Wait and take their
		// result outright rather than re-testing freshness afterwards: with a
		// short window the answer could already be stale by the time they
		// finish, and every waiter would then start its own collection — the
		// very pile-up this exists to prevent. A result gathered moments ago is
		// what the caller wanted.
		wait := g.done
		g.mu.Unlock()
		<-wait

		g.mu.Lock()
		v := g.value
		g.mu.Unlock()
		return v
	}

	g.running = true
	g.done = make(chan struct{})
	done := g.done
	g.mu.Unlock()

	v := collect()

	g.mu.Lock()
	g.value, g.at = v, time.Now()
	g.running = false
	g.mu.Unlock()
	close(done) // releases everyone who queued behind this collection

	return v
}
