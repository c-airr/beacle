package main

import (
	"encoding/json"
	"testing"
	"time"

	"beacle/shared"
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

// The 404 has to reach the panel too. The mux answers an unknown route in
// plain text, which is not JSON, and the result frame carries its body as raw
// JSON: the frame failed to marshal and was never sent.
func TestUnknownRouteResultReachesThePanel(t *testing.T) {
	s := &APIServer{cfg: &Config{Token: "t"}}
	code, resp := s.Dispatch("GET", "/api/route-from-a-newer-panel", nil)
	b, err := commandResult("r1", code, resp)
	if err != nil {
		t.Fatalf("result not framed: %v", err)
	}
	var msg shared.AgentWSMessage
	if err := json.Unmarshal(b, &msg); err != nil || msg.Result == nil {
		t.Fatalf("frame %s: %v", b, err)
	}
	var body any
	if err := json.Unmarshal(msg.Result.Body, &body); err != nil {
		t.Fatalf("body %s: %v", msg.Result.Body, err)
	}
	if msg.Result.StatusCode != 404 || msg.Result.RequestID != "r1" {
		t.Fatalf("result %+v", msg.Result)
	}
	if _, isText := body.(string); !isText {
		t.Fatalf("an unknown route must read as text, not an error object: %#v", body)
	}

	// JSON answers pass through untouched.
	b, _ = commandResult("r2", 404, []byte(`{"error":"no such file"}`))
	_ = json.Unmarshal(b, &msg)
	if string(msg.Result.Body) != `{"error":"no such file"}` {
		t.Fatalf("json body changed: %s", msg.Result.Body)
	}
}
