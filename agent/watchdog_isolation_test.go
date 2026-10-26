package main

import (
	"errors"
	"strings"
	"sync"
	"testing"

	"beacle/shared"
)

var errNoLine = errors.New("no internet")

// fakeFleet drives the watchdog loop without a network: which peers answer,
// whether this watcher's own line is up, and every notice that went out.
type fakeFleet struct {
	mu     sync.Mutex
	up     map[string]bool // peer id -> answers probes
	online bool            // this watcher's own internet
	sent   []string
}

func withFakeFleet(t *testing.T, online bool, up map[string]bool) *fakeFleet {
	t.Helper()
	f := &fakeFleet{up: up, online: online}
	pp, iu, sw := probePeer, internetUp, sendWebhook
	probePeer = func(p shared.WatchdogPeer) bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.up[p.ID]
	}
	internetUp = func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.online
	}
	sendWebhook = func(_ shared.WebhookTarget, msg shared.WebhookMessage) error {
		f.mu.Lock()
		defer f.mu.Unlock()
		if !f.online {
			return errNoLine
		}
		f.sent = append(f.sent, msg.Title)
		return nil
	}
	t.Cleanup(func() { probePeer, internetUp, sendWebhook = pp, iu, sw })
	return f
}

func (f *fakeFleet) set(online bool, up map[string]bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.online = online
	f.up = up
}

func (f *fakeFleet) notices() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.sent...)
}

func fleetFixture(peers ...string) (*watchdog, shared.WatchdogConfig) {
	wc := shared.WatchdogConfig{
		Enabled: true, Role: "primary", SelfID: "home",
		Webhooks: []shared.WebhookTarget{{ID: "d", Kind: shared.WebhookDiscord, URL: "https://example.invalid/hook"}},
		Peers:    []shared.WatchdogPeer{{ID: "home", Name: "home", Host: "100.64.0.1"}},
	}
	for i, p := range peers {
		wc.Peers = append(wc.Peers, shared.WatchdogPeer{ID: p, Name: p, Host: "100.64.0." + string(rune('2'+i))})
	}
	return &watchdog{cfg: wc, down: map[string]int{}, announced: map[string]bool{}}, wc
}

func peerDownNotices(sent []string) []string {
	var out []string
	for _, s := range sent {
		if strings.Contains(s, "unreachable") {
			out = append(out, s)
		}
	}
	return out
}

// The watcher sits on the same line as the panel. The line drops: the tunnel
// goes, and so does every peer. When the line comes back Discord answers a
// tick before Tailscale has found the peers again — that tick used to send a
// "[critical] X unreachable" for every server in the fleet, all of them fine.
func TestWatchdogQuietWhenItsOwnLineDrops(t *testing.T) {
	w, wc := fleetFixture("fra", "waw", "nyc")
	f := withFakeFleet(t, false, map[string]bool{})
	for range watchdogDownAfter + 2 {
		w.probePeers(wc, true)
	}
	f.set(true, map[string]bool{}) // line back, tailnet not yet
	w.probePeers(wc, true)
	f.set(true, map[string]bool{"fra": true, "waw": true, "nyc": true})
	w.probePeers(wc, true)

	if got := peerDownNotices(f.notices()); len(got) != 0 {
		t.Fatalf("watcher blamed the fleet for its own outage: %q", got)
	}
}

// The line is up but the watcher's own Tailscale is not: no peer answers.
// Every server going at once is the watcher, not the fleet.
func TestWatchdogQuietWhenNoPeerAnswers(t *testing.T) {
	w, wc := fleetFixture("fra", "waw", "nyc")
	f := withFakeFleet(t, true, map[string]bool{})
	for range watchdogDownAfter + 3 {
		w.probePeers(wc, true)
	}
	if got := peerDownNotices(f.notices()); len(got) != 0 {
		t.Fatalf("every peer reported down at once: %q", got)
	}
}

// After an outage of its own, a peer has to fail a full fresh run before it
// is announced — the failures counted while the watcher was cut off say
// nothing about the peer.
func TestWatchdogRestartsCountAfterIsolation(t *testing.T) {
	w, wc := fleetFixture("fra", "waw", "nyc")
	f := withFakeFleet(t, false, map[string]bool{})
	for range watchdogDownAfter {
		w.probePeers(wc, true)
	}
	f.set(true, map[string]bool{"fra": true, "waw": true}) // nyc really down
	for range watchdogDownAfter - 1 {
		w.probePeers(wc, true)
	}
	if got := peerDownNotices(f.notices()); len(got) != 0 {
		t.Fatalf("announced on failures counted while isolated: %q", got)
	}
	w.probePeers(wc, true)
	if got := peerDownNotices(f.notices()); len(got) != 1 || !strings.Contains(got[0], "nyc") {
		t.Fatalf("a real outage after isolation: notices %q, want one for nyc", got)
	}
}

// The guard must not hide a real outage: one server gone while the rest
// answer is announced, once.
func TestWatchdogStillReportsOnePeerDown(t *testing.T) {
	w, wc := fleetFixture("fra", "waw", "nyc")
	f := withFakeFleet(t, true, map[string]bool{"fra": true, "waw": true})
	for range watchdogDownAfter + 2 {
		w.probePeers(wc, true)
	}
	if got := peerDownNotices(f.notices()); len(got) != 1 || !strings.Contains(got[0], "nyc") {
		t.Fatalf("notices %q, want exactly one for nyc", got)
	}
}

// With a single peer "all peers down" proves nothing, so only the watcher's
// own line can excuse it — a two-server fleet still gets its alert.
func TestWatchdogSinglePeerDownIsReported(t *testing.T) {
	w, wc := fleetFixture("fra")
	f := withFakeFleet(t, true, map[string]bool{})
	for range watchdogDownAfter {
		w.probePeers(wc, true)
	}
	if got := peerDownNotices(f.notices()); len(got) != 1 {
		t.Fatalf("notices %q, want one for fra", got)
	}
}

// A peer with SSH off port 22 and ICMP filtered still runs an agent that
// answers the liveness route; that answer alone makes it up.
func TestPeerProbeAsksTheAgentFirst(t *testing.T) {
	pa, ph := probeAgent, probeHost
	t.Cleanup(func() { probeAgent, probeHost = pa, ph })
	probeAgent = func(shared.WatchdogPeer) bool { return true }
	probeHost = func(string) bool { return false }
	if !peerReachable(shared.WatchdogPeer{ID: "fra", Host: "100.64.0.2"}) {
		t.Fatal("peer whose agent answers read as down because SSH and ping did not")
	}
}

// A two-server fleet, watcher on the home line that just dropped: its lone
// peer is silent, but so is the internet. Nothing is announced.
func TestWatchdogSinglePeerQuietWhenLineIsDown(t *testing.T) {
	w, wc := fleetFixture("fra")
	f := withFakeFleet(t, false, map[string]bool{})
	for range watchdogDownAfter + 1 {
		w.probePeers(wc, true)
	}
	f.set(true, map[string]bool{})
	w.probePeers(wc, true)
	if got := peerDownNotices(f.notices()); len(got) != 0 {
		t.Fatalf("notices %q while the watcher's own line was down", got)
	}
}

// verifyPeers stubs the probes per peer: alive[id] is whether its agent
// answers, host[id] whether the host does.
func verifyPeers(t *testing.T, alive, host map[string]bool, online bool) {
	t.Helper()
	pa, ph, pp, iu, gap := probeAgent, probeHost, probePeer, internetUp, verifyRetryGap
	verifyRetryGap = 0
	hostOf := map[string]string{"maslo": "100.64.0.1", "arm": "100.64.0.2", "fra": "100.64.0.3"}
	probeAgent = func(p shared.WatchdogPeer) bool { return alive[p.ID] }
	probeHost = func(h string) bool {
		for id, hh := range hostOf {
			if hh == h {
				return host[id]
			}
		}
		return false
	}
	probePeer = peerReachable
	internetUp = func() bool { return online }
	t.Cleanup(func() { probeAgent, probeHost, probePeer, internetUp, verifyRetryGap = pa, ph, pp, iu, gap })
}

func threePeerFixture() *watchdog {
	w := verifyFixture()
	w.cfg.Peers = append(w.cfg.Peers, shared.WatchdogPeer{ID: "fra", Name: "fra", Host: "100.64.0.3"})
	return w
}

// The watcher shares the panel's home line and is coming back from the same
// outage: arm is silent, and so is fra. It used to confirm "VPS offline" for
// a server that was fine; now it declines and the panel asks the other
// watcher.
func TestVerifyCannotVouchWhenCutOff(t *testing.T) {
	verifyPeers(t, map[string]bool{}, map[string]bool{}, true)
	_, send, _, err := threePeerFixture().verify(agentDownMsg("arm"))
	if send || !errors.Is(err, errCannotVouch) {
		t.Fatalf("send=%v err=%v, want errCannotVouch", send, err)
	}
}

func TestVerifyConfirmsWhenAWitnessAnswers(t *testing.T) {
	verifyPeers(t, map[string]bool{"fra": true}, map[string]bool{}, true)
	msg, send, _, err := threePeerFixture().verify(agentDownMsg("arm"))
	if err != nil || !send || msg.Alert != string(shared.AlertAgentOffline) {
		t.Fatalf("send=%v err=%v msg=%+v", send, err, msg)
	}
}

// No witness besides the subject: the watcher's own line decides.
func TestVerifyCannotVouchWithoutInternet(t *testing.T) {
	verifyPeers(t, map[string]bool{}, map[string]bool{}, false)
	_, _, _, err := verifyFixture().verify(agentDownMsg("arm"))
	if !errors.Is(err, errCannotVouch) {
		t.Fatalf("err=%v, want errCannotVouch", err)
	}
}

// The panel turns a watcher's refusal into "ask the other one".
func TestDeliverCannotVouchIsAnError(t *testing.T) {
	verifyPeers(t, map[string]bool{}, map[string]bool{}, true)
	_, err := threePeerFixture().deliver(agentDownMsg("arm"))
	if err == nil {
		t.Fatal("deliver answered success for an alert it could not check")
	}
}
