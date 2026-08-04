package main

import (
	"testing"
	"time"
)

// A panel talking to an older agent asks for routes that agent has never heard
// of. That has to fail immediately: the backend waits 30s for a tunnel reply,
// so a request that is silently dropped freezes whatever the user clicked for
// half a minute instead of saying "not supported".
func TestUnknownRouteAnswers404(t *testing.T) {
	s := &APIServer{cfg: &Config{Token: "t"}}

	done := make(chan int, 1)
	go func() {
		code, _ := s.Dispatch("GET", "/api/route-from-a-newer-panel", nil)
		done <- code
	}()

	select {
	case code := <-done:
		if code != 404 {
			t.Errorf("unknown route returned %d, want 404", code)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Dispatch never returned for an unknown route")
	}
}
