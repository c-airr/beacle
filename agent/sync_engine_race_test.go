package main

import (
	"context"
	"sync"
	"testing"
	"time"

	"beacle/shared"
)

// A dropped WebSocket session used to kill the agent outright: the session
// cancelled its context and closed the write channel one line later, and any
// push already past its context check landed its send on the closed channel.
// "panic: send on closed channel", every time a session ended mid-push.
//
// This drives sends and session teardown against each other hard enough that
// the old ordering would panic, and asserts only that the agent survives.
func TestSendSurvivesSessionEndingMidPush(t *testing.T) {
	for round := 0; round < 50; round++ {
		writeCh := make(chan []byte, 4)
		ctx, cancel := context.WithCancel(context.Background())

		e := NewSyncEngine(&Config{VPSID: "test"}, nil, writeCh)
		e.mu.Lock()
		e.done = ctx.Done()
		e.mu.Unlock()

		// A reader that stops the moment the session does, the way writePump
		// returns on ctx.Done — so the buffer fills and senders block.
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case <-writeCh:
				}
			}
		}()

		var wg sync.WaitGroup
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for j := 0; j < 200; j++ {
					// Errors are expected once the session ends; a panic is not.
					_ = e.send(shared.AgentWSMetrics, func(*shared.AgentWSMessage) {})
				}
			}()
		}

		time.Sleep(time.Duration(round%3) * time.Millisecond)
		cancel()
		wg.Wait()
	}
}

// PushAll runs in its own goroutine (SetPowerMode and RequestRefresh both spawn
// it), so it can reach a send well after the session it belonged to is gone.
func TestSendAfterSessionEndedReturnsError(t *testing.T) {
	writeCh := make(chan []byte, 1)
	ctx, cancel := context.WithCancel(context.Background())

	e := NewSyncEngine(&Config{VPSID: "test"}, nil, writeCh)
	e.mu.Lock()
	e.done = ctx.Done()
	e.mu.Unlock()

	cancel()
	time.Sleep(10 * time.Millisecond)

	if err := e.send(shared.AgentWSMetrics, func(*shared.AgentWSMessage) {}); err == nil {
		t.Error("send into a finished session should report an error, not succeed silently")
	}
}
