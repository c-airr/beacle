package main

import (
	"encoding/json"
	"testing"
	"time"

	"beacle/shared"
)

// fakeAgent puts a registered agent session into the hub without a socket;
// frames the hub sends to it land in sess.send.
func fakeAgent(h *AgentHub, vpsID string) *agentSession {
	sess := &agentSession{vpsID: vpsID, send: make(chan []byte, 64), done: make(chan struct{})}
	sess.registered.Store(true)
	h.mu.Lock()
	h.agents[vpsID] = sess
	h.mu.Unlock()
	return sess
}

func sentFrame(t *testing.T, sess *agentSession) shared.TerminalFrame {
	t.Helper()
	select {
	case b := <-sess.send:
		var msg shared.AgentWSMessage
		if err := json.Unmarshal(b, &msg); err != nil || msg.Terminal == nil {
			t.Fatalf("not a terminal frame: %s", b)
		}
		return *msg.Terminal
	case <-time.After(time.Second):
		t.Fatal("nothing sent to the agent")
	}
	return shared.TerminalFrame{}
}

func appFrame(t *testing.T, ts *termSub) shared.TerminalFrame {
	t.Helper()
	select {
	case f := <-ts.out:
		return f
	case <-time.After(time.Second):
		t.Fatal("nothing delivered to the app")
	}
	return shared.TerminalFrame{}
}

func TestTerminalRelaysBothWays(t *testing.T) {
	h := NewAgentHub(nil, nil, nil, nil, nil)
	agent := fakeAgent(h, "vps1")

	ts, err := h.OpenTerminal("vps1", 120, 40)
	if err != nil {
		t.Fatal(err)
	}
	open := sentFrame(t, agent)
	if open.Op != shared.TermOpen || open.Cols != 120 || open.Rows != 40 || open.Session != ts.id {
		t.Fatalf("open frame = %+v", open)
	}

	h.TerminalInput(ts, shared.TerminalFrame{Session: "spoofed", Op: shared.TermData, Data: "bHM="})
	if in := sentFrame(t, agent); in.Session != ts.id || in.Data != "bHM=" {
		t.Fatalf("input must carry the real session id: %+v", in)
	}

	h.handleTerminalFrame(agent, &shared.TerminalFrame{Session: ts.id, Op: shared.TermData, Data: "b2s="})
	if f := appFrame(t, ts); f.Data != "b2s=" {
		t.Fatalf("output = %+v", f)
	}

	h.CloseTerminal(ts)
	if f := sentFrame(t, agent); f.Op != shared.TermClose {
		t.Fatalf("closing the app side must hang up the shell, sent %+v", f)
	}
}

func TestAnotherAgentCannotWriteIntoASession(t *testing.T) {
	h := NewAgentHub(nil, nil, nil, nil, nil)
	fakeAgent(h, "vps1")
	other := fakeAgent(h, "vps2")
	ts, _ := h.OpenTerminal("vps1", 80, 24)

	h.handleTerminalFrame(other, &shared.TerminalFrame{Session: ts.id, Op: shared.TermData, Data: "ZXZpbA=="})
	select {
	case f := <-ts.out:
		t.Fatalf("frame from a different agent reached the app: %+v", f)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestTerminalOnOfflineServerFails(t *testing.T) {
	h := NewAgentHub(nil, nil, nil, nil, nil)
	if _, err := h.OpenTerminal("nope", 80, 24); err == nil {
		t.Fatal("want an error for a server with no agent socket")
	}
}

func TestAgentDropEndsTheTerminal(t *testing.T) {
	h := NewAgentHub(nil, nil, nil, nil, nil)
	agent := fakeAgent(h, "vps1")
	ts, _ := h.OpenTerminal("vps1", 80, 24)
	sentFrame(t, agent) // open

	close(agent.done)
	if f := appFrame(t, ts); f.Op != shared.TermError {
		t.Fatalf("want an error frame after the agent dropped, got %+v", f)
	}
}

func TestShellExitForgetsTheSession(t *testing.T) {
	h := NewAgentHub(nil, nil, nil, nil, nil)
	agent := fakeAgent(h, "vps1")
	ts, _ := h.OpenTerminal("vps1", 80, 24)
	sentFrame(t, agent)

	h.handleTerminalFrame(agent, &shared.TerminalFrame{Session: ts.id, Op: shared.TermExit, Code: 0})
	if f := appFrame(t, ts); f.Op != shared.TermExit {
		t.Fatalf("got %+v", f)
	}
	h.mu.Lock()
	_, still := h.terms[ts.id]
	h.mu.Unlock()
	if still {
		t.Fatal("exited session still routed")
	}
	// The app closing afterwards must not send a close for a shell that is gone.
	h.CloseTerminal(ts)
	select {
	case b := <-agent.send:
		t.Fatalf("sent %s for an already-exited shell", b)
	default:
	}
}

func TestOldAgentsAreToldToUpdateInsteadOfHanging(t *testing.T) {
	for v, want := range map[string]bool{
		"1.2.0": false, "1.1": false, "0.9.1": false,
		"2.0.0": true, "v2.1.3": true, "10.0.0": true,
		"": true, "dev": true,
	} {
		if got := agentHasTerminal(v); got != want {
			t.Errorf("agentHasTerminal(%q) = %v, want %v", v, got, want)
		}
	}
}
