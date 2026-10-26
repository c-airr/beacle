package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"beacle/shared"
)

// Watchdog: when the backend goes quiet (panel closed, laptop asleep), the
// two elected watcher agents keep the fleet supervised from the inside. The
// primary sends peer-down notices; the secondary only acts while the primary
// itself is unreachable, so nothing is ever announced twice. While the tunnel
// is up the backend owns all alerting and the loop merely tracks state — a
// notice is only ever sent by one side.
//
// The panel going quiet is not announced: it is a desktop app, and closing
// the lid or the home line dropping is no news to the person it would page.
//
// Peers are probed over Tailscale: the agent's liveness route first, then TCP
// to SSH, then ICMP ping, so a host with a closed SSH port still reads as up.

const (
	watchdogTick      = time.Minute
	watchdogDownAfter = 3 // consecutive failed ticks before a peer reads as down
	peerDialTimeout   = 5 * time.Second
)

type tunnelState interface{ isConnected() bool }

type watchdog struct {
	mu        sync.Mutex
	cfg       shared.WatchdogConfig
	down      map[string]int  // peer id -> consecutive failures
	announced map[string]bool // peer id -> down notice sent
	// isolated is set while no peer answers this watcher (see cutOff).
	isolated bool
}

var wd = &watchdog{down: map[string]int{}, announced: map[string]bool{}}

func watchdogPath(cfg *Config) string {
	return filepath.Join(cfg.StateDir(), "watchdog.json")
}

func loadWatchdogConfig(cfg *Config) shared.WatchdogConfig {
	var wc shared.WatchdogConfig
	raw, err := os.ReadFile(watchdogPath(cfg))
	if err != nil {
		return wc
	}
	_ = json.Unmarshal(raw, &wc)
	return wc
}

func (w *watchdog) setConfig(cfg *Config, wc shared.WatchdogConfig) error {
	data, err := json.MarshalIndent(wc, "", "  ")
	if err != nil {
		return err
	}
	// Webhook URLs are secrets: token-equivalent for Discord/Telegram.
	if err := os.WriteFile(watchdogPath(cfg), data, 0o600); err != nil {
		return err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	wasRole := w.cfg.Role
	w.cfg = wc
	if wc.Role != wasRole {
		// A role change resets peer tracking: the new secondary must not
		// inherit the old primary's announced set and stay silent forever.
		w.down = map[string]int{}
		w.announced = map[string]bool{}
	}
	return nil
}

func (w *watchdog) snapshot() shared.WatchdogConfig {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.cfg
}

func (w *watchdog) sendAll(msg shared.WebhookMessage) error {
	w.mu.Lock()
	targets := append([]shared.WebhookTarget{}, w.cfg.Webhooks...)
	w.mu.Unlock()
	if len(targets) == 0 {
		return fmt.Errorf("no webhooks configured")
	}
	var firstErr error
	sent := 0
	for _, t := range targets {
		if err := sendWebhook(t, msg); err != nil {
			log.Printf("watchdog: %s webhook failed: %v", t.Kind, err)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		sent++
	}
	if sent == 0 {
		return firstErr
	}
	return nil
}

// Seams for tests: the network probes a verification runs, and delivery.
var (
	probeAgent  = agentAlive
	probeHost   = peerUp
	probePeer   = peerReachable
	internetUp  = lineUp
	sendWebhook = shared.SendWebhook
)

var verifyRetryGap = 2 * time.Second

// errCannotVouch is a watcher declining to judge an alert because it is cut
// off itself. The panel then asks the other watcher, which the election puts
// in a different network.
var errCannotVouch = errors.New("this watcher cannot reach the rest of the fleet either")

// peerReachable asks the peer's agent first — its answer is the proof that
// the server is fine, and it needs neither SSH on port 22 nor ICMP — and
// only then the host.
func peerReachable(p shared.WatchdogPeer) bool {
	return probeAgent(p) || probeHost(p.Host)
}

// probeAll probes every peer at once; up[i] is peers[i].
func probeAll(peers []shared.WatchdogPeer) []bool {
	up := make([]bool, len(peers))
	var wg sync.WaitGroup
	for i, p := range peers {
		wg.Go(func() { up[i] = probePeer(p) })
	}
	wg.Wait()
	return up
}

// cutOff reports whether this watcher, not the fleet, is the one that is
// down, from what its witnesses answered. Every server going quiet at once
// is the watcher's own line or its tailnet finding its way back — the same
// home router as the panel, typically — far more often than the whole fleet.
// With no witness at all only the watcher's own internet line can tell.
func cutOff(witnesses []bool) bool {
	if len(witnesses) == 0 {
		return !internetUp()
	}
	for _, up := range witnesses {
		if up {
			return false
		}
	}
	return true
}

// lineTargets answer "does this machine have internet". Plain IPs, so a dead
// resolver does not read as a dead line, two operators and both families, so
// an IPv6-only server can answer too.
var lineTargets = []string{"1.1.1.1:443", "8.8.8.8:443", "[2606:4700:4700::1111]:443", "[2001:4860:4860::8888]:443"}

func lineUp() bool {
	ok := make(chan bool, len(lineTargets))
	for _, t := range lineTargets {
		go func() {
			c, err := net.DialTimeout("tcp", t, peerDialTimeout)
			if err == nil {
				_ = c.Close()
			}
			ok <- err == nil
		}()
	}
	for range lineTargets {
		if <-ok {
			return true
		}
	}
	return false
}

// deliver is the panel's send path. Reachability alerts are the panel's view
// from one computer — a blink in its own connection used to page for every
// agent at once — so they are checked again from here before anything goes
// out. Everything else (metrics, services, certificates) was measured by the
// agent concerned and is passed on as is.
func (w *watchdog) deliver(msg shared.WebhookMessage) (shared.WatchdogSendResult, error) {
	msg, send, reason, err := w.verify(msg)
	if err != nil {
		log.Printf("watchdog: cannot vouch for %q: %v", msg.Title, err)
		return shared.WatchdogSendResult{}, err
	}
	if !send {
		log.Printf("watchdog: not sending %q: %s", msg.Title, reason)
		return shared.WatchdogSendResult{Sent: false, Reason: reason}, nil
	}
	if err := w.sendAll(msg); err != nil {
		return shared.WatchdogSendResult{}, err
	}
	return shared.WatchdogSendResult{Sent: true}, nil
}

// verify decides whether a reachability alert holds from this watcher, and
// rewrites it to what this watcher actually sees: the panel may say "agent
// down" for a host this side cannot reach at all, or the other way round.
// Only positive proof — the agent answering — suppresses an alert; a peer
// this watcher knows nothing about is passed on unchecked. A watcher that
// cannot see the rest of the fleet either does not confirm anything: it
// returns errCannotVouch.
func (w *watchdog) verify(msg shared.WebhookMessage) (shared.WebhookMessage, bool, string, error) {
	if msg.VPSID == "" || (msg.Alert != string(shared.AlertAgentDown) && msg.Alert != string(shared.AlertAgentOffline)) {
		return msg, true, "", nil
	}
	wc := w.snapshot()
	self := wc.SelfID
	var peer *shared.WatchdogPeer
	var witnesses []shared.WatchdogPeer
	for i := range wc.Peers {
		switch wc.Peers[i].ID {
		case wc.SelfID:
			self = wc.Peers[i].Name
		case msg.VPSID:
			peer = &wc.Peers[i]
		default:
			witnesses = append(witnesses, wc.Peers[i])
		}
	}
	if msg.VPSID == wc.SelfID {
		return msg, false, "the alert is about this watcher, and it is running", nil
	}
	if peer == nil {
		return msg, true, "", nil
	}
	alive := probeAgent(*peer)
	if !alive {
		// One more try: a single lost packet must not decide it either way.
		time.Sleep(verifyRetryGap)
		alive = probeAgent(*peer)
	}
	if alive {
		return msg, false, peer.Name + "'s agent answers " + self, nil
	}
	// About to page someone on this watcher's word. If none of the other
	// servers answers it either, it is the one cut off — the same line as
	// the panel, coming back from the same outage — and its "no answer"
	// says nothing about the peer.
	if cutOff(probeAll(witnesses)) {
		return msg, false, "", errCannotVouch
	}
	name := msg.VPSName
	if name == "" {
		name = peer.Name
	}
	sev := msg.Severity
	if sev == "" {
		sev = "critical"
	}
	if probeHost(peer.Host) {
		msg.Alert = string(shared.AlertAgentDown)
		msg.Title = "[" + sev + "] " + name + ": agent down"
		msg.Body = shared.MsgAgentDown
	} else {
		msg.Alert = string(shared.AlertAgentOffline)
		msg.Title = "[" + sev + "] " + name + ": VPS offline"
		msg.Body = shared.MsgAgentOffline
	}
	msg.Body += " (confirmed by " + self + ")"
	return msg, true, "", nil
}

// peerUp probes one host: SSH first, ping as the fallback.
func peerUp(host string) bool {
	if host == "" {
		return false
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, "22"), peerDialTimeout)
	if err == nil {
		_ = conn.Close()
		return true
	}
	out, err := exec.Command("ping", "-c1", "-W3", host).CombinedOutput()
	_ = out
	return err == nil
}

// runWatchdog is started once from main and lives as long as the agent.
func runWatchdog(cfg *Config, tunnel tunnelState) {
	wd.mu.Lock()
	wd.cfg = loadWatchdogConfig(cfg)
	wd.mu.Unlock()
	ticker := time.NewTicker(watchdogTick)
	defer ticker.Stop()
	for range ticker.C {
		watchdogTickOnce(cfg, tunnel)
	}
}

func watchdogTickOnce(cfg *Config, tunnel tunnelState) {
	wc := wd.snapshot()
	if !wc.Enabled || len(wc.Webhooks) == 0 {
		return
	}
	connected := tunnel != nil && tunnel.isConnected()
	if connected {
		// Track peers silently so a backend outage starts from warm state,
		// but never announce while the backend owns alerting.
		wd.probePeers(wc, false)
		return
	}
	wd.probePeers(wc, true)
}

// allowedToSendLocked implements the primary/secondary rule: the secondary
// stays silent while the primary answers its probes.
func (w *watchdog) allowedToSendLocked(wc shared.WatchdogConfig) bool {
	if wc.Role != "secondary" || wc.PrimaryID == "" || wc.PrimaryID == wc.SelfID {
		return true
	}
	return w.announced[wc.PrimaryID]
}

// probePeers checks every peer except self. announce=false only warms the
// failure counters (tunnel up); announce=true sends down/recovery notices.
func (w *watchdog) probePeers(wc shared.WatchdogConfig, announce bool) {
	var peers []shared.WatchdogPeer
	for _, p := range wc.Peers {
		if p.ID != wc.SelfID {
			peers = append(peers, p)
		}
	}
	// The backend lists this watcher among the peers. Waiting for one answer
	// per listed peer while self is never probed hung the loop on its first
	// tick, for good.
	up := probeAll(peers)

	// Each peer is the others' witness; a lone peer has none.
	witnesses := up
	if len(peers) < 2 {
		witnesses = nil
	}
	if cutOff(witnesses) {
		// Failures counted while this watcher was cut off say nothing about
		// the peers, so each one fails a full fresh run before it is
		// announced. Announced peers stay announced, for their recovery.
		w.mu.Lock()
		if !w.isolated {
			log.Printf("watchdog: no peer answers this watcher, holding notices")
		}
		w.isolated = true
		w.down = map[string]int{}
		w.mu.Unlock()
		return
	}
	w.mu.Lock()
	w.isolated = false
	w.mu.Unlock()

	for i, peer := range peers {
		w.mu.Lock()
		if up[i] {
			wasAnnounced := w.announced[peer.ID]
			w.down[peer.ID] = 0
			w.announced[peer.ID] = false
			allow := w.allowedToSendLocked(wc)
			w.mu.Unlock()
			if wasAnnounced && announce && allow {
				_ = w.sendAll(shared.WebhookMessage{
					Title:    "[info] " + peer.Name + " reachable again",
					Body:     "Peer answers probes.",
					Severity: "info",
				})
			}
			continue
		}
		w.down[peer.ID]++
		failures := w.down[peer.ID]
		already := w.announced[peer.ID]
		allow := w.allowedToSendLocked(wc)
		w.mu.Unlock()
		if announce && !already && failures >= watchdogDownAfter && allow {
			err := w.sendAll(shared.WebhookMessage{
				Title:    "[critical] " + peer.Name + " unreachable",
				Body:     fmt.Sprintf("No answer on %s for %d minutes (backend tunnel down — reported by fleet watcher).", peer.Host, failures),
				Severity: "critical",
			})
			if err != nil {
				log.Printf("watchdog: peer-down notice failed: %v", err)
				continue
			}
			w.mu.Lock()
			w.announced[peer.ID] = true
			w.mu.Unlock()
		}
	}
}
