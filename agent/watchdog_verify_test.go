package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"beacle/shared"
)

func withProbes(t *testing.T, agent, host bool) {
	t.Helper()
	pa, ph, gap := probeAgent, probeHost, verifyRetryGap
	verifyRetryGap = 0
	probeAgent = func(shared.WatchdogPeer) bool { return agent }
	probeHost = func(string) bool { return host }
	t.Cleanup(func() { probeAgent, probeHost, verifyRetryGap = pa, ph, gap })
}

func verifyFixture() *watchdog {
	return &watchdog{cfg: shared.WatchdogConfig{
		Enabled: true, Role: "primary", SelfID: "maslo",
		Peers: []shared.WatchdogPeer{
			{ID: "maslo", Name: "maslo", Host: "100.64.0.1"},
			{ID: "arm", Name: "arm", Host: "100.64.0.2"},
		},
	}, down: map[string]int{}, announced: map[string]bool{}}
}

func agentDownMsg(id string) shared.WebhookMessage {
	return shared.WebhookMessage{
		Title: "[critical] " + id + ": agent down", Body: shared.MsgAgentDown,
		Severity: "critical", VPSID: id, VPSName: id, Alert: string(shared.AlertAgentDown),
	}
}

// The panel lost its tunnel to arm, but arm's agent answers the watcher:
// the panel's connection blinked, not the agent. Nothing goes out.
func TestVerifySuppressesWhenAgentAnswers(t *testing.T) {
	withProbes(t, true, true)
	_, send, reason := verifyFixture().verify(agentDownMsg("arm"))
	if send {
		t.Fatal("alert sent although arm's agent answers the watcher")
	}
	if !strings.Contains(reason, "arm") {
		t.Errorf("reason %q should name the server", reason)
	}
}

func TestVerifyConfirmsAgentDown(t *testing.T) {
	withProbes(t, false, true)
	msg, send, _ := verifyFixture().verify(agentDownMsg("arm"))
	if !send || msg.Alert != string(shared.AlertAgentDown) || !strings.Contains(msg.Body, "confirmed by maslo") {
		t.Fatalf("send=%v msg=%+v", send, msg)
	}
}

// The panel says "agent down" but from the watcher the whole host is gone:
// the message says what the watcher sees.
func TestVerifyRewritesToOffline(t *testing.T) {
	withProbes(t, false, false)
	msg, send, _ := verifyFixture().verify(agentDownMsg("arm"))
	if !send || msg.Alert != string(shared.AlertAgentOffline) || !strings.Contains(msg.Title, "VPS offline") {
		t.Fatalf("send=%v msg=%+v", send, msg)
	}
}

func TestVerifyPassesOtherAlertsUntouched(t *testing.T) {
	withProbes(t, true, true)
	in := shared.WebhookMessage{Title: "[warning] arm: CPU high", Body: "x", VPSID: "arm", Alert: string(shared.AlertCPUHigh)}
	out, send, _ := verifyFixture().verify(in)
	if !send || out != in {
		t.Fatalf("metric alert changed or dropped: %+v", out)
	}
}

func TestVerifyUnknownPeerPassesThrough(t *testing.T) {
	withProbes(t, true, true)
	_, send, _ := verifyFixture().verify(agentDownMsg("stranger"))
	if !send {
		t.Fatal("an alert about a server the watcher cannot check must still go out")
	}
}

func TestVerifyAboutSelf(t *testing.T) {
	withProbes(t, false, false)
	_, send, _ := verifyFixture().verify(agentDownMsg("maslo"))
	if send {
		t.Fatal("a watcher answering the request is alive; it must not report itself down")
	}
}

func TestAgentAliveChecksIdentity(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != shared.AgentLivenessPath {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"id":"arm","version":"x","backend":false}`))
	}))
	defer srv.Close()
	host, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	p, _ := strconv.Atoi(port)
	if !agentAlive(shared.WatchdogPeer{ID: "arm", Host: host, AgentPort: p}) {
		t.Error("arm answering as arm should read as alive")
	}
	if agentAlive(shared.WatchdogPeer{ID: "2rd", Host: host, AgentPort: p}) {
		t.Error("a different agent answering on that address is not proof 2rd is alive")
	}
}
