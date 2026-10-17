package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"beacle/shared"
)

// Outgoing notifications. Delivery always runs from the fleet itself, never
// from this computer: the backend elects two online VPSes as watchers
// (primary + secondary) and pushes them the webhook targets plus the peer
// list. Every alert is then handed to a watcher over the command tunnel. The
// panel is the first layer — it notices — and the watcher the second: an
// "agent down" or "offline" claim is checked again from the watcher before
// it pages anyone, so a blink in this computer's own connection no longer
// reads as the whole fleet dying. When neither watcher can be reached the
// alert stays in the panel; the watchers supervise the fleet on their own
// while their tunnel is down (see agent/watchdog.go), so a dead panel still
// means notified phones rather than silent servers.
//
// Stability is sample coverage over the last 24h — a host that flapped has
// gaps — with fleet seniority as the tiebreak. When the backend itself was
// off most of the day every host ties and the two oldest win, which is the
// sanest answer available: the longest-proven boxes. The two are kept in
// different networks (egress address) when the fleet allows it, so one home
// router or one provider outage cannot silence both. Either seat can be
// pinned to a chosen server; a pinned server that is offline falls back to
// the automatic choice until it returns.

const (
	watcherSyncEvery   = 5 * time.Minute
	watcherStability   = 24 * time.Hour
	watchdogPushBudget = 15 * time.Second
	// A send may verify the alert first (agent probe with one retry, then a
	// host probe) and then post to every target in turn.
	watchdogSendBudget = 45 * time.Second
)

type WebhookService struct {
	mu      sync.Mutex
	path    string
	targets []shared.WebhookTarget
	// Pinned watchers; blank means automatic.
	pinPrimary   string
	pinSecondary string

	store    *Store
	agentHub *AgentHub
	history  *History

	queue  chan shared.WebhookMessage
	syncMu sync.Mutex // syncWatchers runs alone; overlapping ticks skip
	pushed string     // pairKey of the last election pushed to the fleet
}

func NewWebhookService(dataDir string, store *Store, hub *AgentHub, history *History) *WebhookService {
	w := &WebhookService{
		path:     filepath.Join(dataDir, "webhooks.json"),
		store:    store,
		agentHub: hub,
		history:  history,
		queue:    make(chan shared.WebhookMessage, 64),
	}
	if raw, err := os.ReadFile(w.path); err == nil {
		var saved webhooksFile
		if json.Unmarshal(raw, &saved) == nil {
			w.targets = saved.Targets
			w.pinPrimary = saved.Primary
			w.pinSecondary = saved.Secondary
		}
	}
	return w
}

type webhooksFile struct {
	Targets   []shared.WebhookTarget `json:"targets"`
	Primary   string                 `json:"primary_id,omitempty"`
	Secondary string                 `json:"secondary_id,omitempty"`
}

// persistLocked writes through a temporary file: a write cut short must not
// leave a truncated webhooks.json, which loads as no destinations at all.
func (w *WebhookService) persistLocked() error {
	data, err := json.MarshalIndent(webhooksFile{
		Targets: w.targets, Primary: w.pinPrimary, Secondary: w.pinSecondary,
	}, "", "  ")
	if err != nil {
		return err
	}
	tmp := w.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("save notifications: %w", err)
	}
	if err := os.Rename(tmp, w.path); err != nil {
		return fmt.Errorf("save notifications: %w", err)
	}
	return nil
}

func newWebhookID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Targets returns a copy of the configured destinations.
func (w *WebhookService) Targets() []shared.WebhookTarget {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]shared.WebhookTarget{}, w.targets...)
}

// SetTargets replaces the destination list (validating each) and re-pushes
// the fleet so watchers learn the new URLs within seconds.
func (w *WebhookService) SetTargets(targets []shared.WebhookTarget) error {
	for i := range targets {
		targets[i].Kind = stringNormalize(targets[i].Kind)
		if targets[i].ID == "" {
			targets[i].ID = newWebhookID()
		}
		if err := shared.ValidateWebhookTarget(targets[i]); err != nil {
			return err
		}
	}
	w.mu.Lock()
	w.targets = targets
	err := w.persistLocked()
	w.mu.Unlock()
	go w.SyncWatchers()
	return err
}

// Pins returns the pinned watcher IDs (blank = automatic).
func (w *WebhookService) Pins() (primary, secondary string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.pinPrimary, w.pinSecondary
}

// SetPins pins either seat to a server, or back to automatic with "". The
// same server cannot hold both seats.
func (w *WebhookService) SetPins(primary, secondary string) error {
	if primary != "" && primary == secondary {
		return fmt.Errorf("primary and backup sender must be different servers")
	}
	for _, id := range []string{primary, secondary} {
		if id == "" {
			continue
		}
		if w.store.GetVPS(id) == nil {
			return fmt.Errorf("unknown server %q", id)
		}
	}
	w.mu.Lock()
	w.pinPrimary, w.pinSecondary = primary, secondary
	err := w.persistLocked()
	w.mu.Unlock()
	go w.SyncWatchers()
	return err
}

// Enqueue hands an alert to the delivery worker without blocking evaluation.
func (w *WebhookService) Enqueue(msg shared.WebhookMessage) {
	select {
	case w.queue <- msg:
	default:
		log.Printf("webhooks: delivery queue full, dropping %q", msg.Title)
	}
}

// Run delivers queued alerts until the process ends.
func (w *WebhookService) Run() {
	for msg := range w.queue {
		via, suppressed, err := w.deliver(msg)
		if err != nil {
			log.Printf("webhooks: %q failed: %v", msg.Title, err)
			continue
		}
		if suppressed != "" {
			log.Printf("webhooks: %q not sent by %s: %s", msg.Title, via, suppressed)
			continue
		}
		log.Printf("webhooks: %q via %s", msg.Title, via)
	}
}

// RunSyncLoop re-elects watchers on a timer and once at startup.
func (w *WebhookService) RunSyncLoop() {
	w.SyncWatchers()
	for range time.Tick(watcherSyncEvery) {
		w.SyncWatchers()
	}
}

// Elect picks the two watchers. Empty when nobody is online.
func (w *WebhookService) Elect() (primary, secondary *shared.VPS) {
	var cands []shared.VPS
	for _, v := range w.store.ListVPS() {
		if v.Status == shared.VPSPending {
			continue
		}
		if !w.agentHub.Connected(v.ID) {
			continue
		}
		cands = append(cands, v)
	}
	since := time.Now().Add(-watcherStability)
	coverage := map[string]int{}
	for _, v := range cands {
		coverage[v.ID] = len(w.history.Query(v.ID, since, time.Now()))
	}
	pinP, pinS := w.Pins()
	return electWatchers(cands, coverage, pinP, pinS)
}

// electWatchers ranks the online candidates by stability and fills both
// seats: a pinned server that is online keeps its seat, the rest go to the
// most stable server left — for the second seat, preferably one outside the
// first one's network.
func electWatchers(cands []shared.VPS, coverage map[string]int, pinP, pinS string) (primary, secondary *shared.VPS) {
	if len(cands) == 0 {
		return nil, nil
	}
	cands = append([]shared.VPS{}, cands...)
	sort.Slice(cands, func(i, j int) bool {
		if coverage[cands[i].ID] != coverage[cands[j].ID] {
			return coverage[cands[i].ID] > coverage[cands[j].ID]
		}
		if !cands[i].CreatedAt.Equal(cands[j].CreatedAt) {
			return cands[i].CreatedAt.Before(cands[j].CreatedAt)
		}
		return cands[i].ID < cands[j].ID
	})
	byID := func(id string) *shared.VPS {
		for i := range cands {
			if id != "" && cands[i].ID == id {
				return &cands[i]
			}
		}
		return nil
	}
	// best is the most stable candidate other than taken, outside taken's
	// network when any such candidate exists.
	best := func(taken *shared.VPS) *shared.VPS {
		var fallback *shared.VPS
		for i := range cands {
			c := &cands[i]
			if taken != nil && c.ID == taken.ID {
				continue
			}
			if taken == nil || !sameNetwork(*c, *taken) {
				return c
			}
			if fallback == nil {
				fallback = c
			}
		}
		return fallback
	}
	primary = byID(pinP)
	secondary = byID(pinS)
	if secondary != nil && primary != nil && secondary.ID == primary.ID {
		secondary = nil
	}
	if primary == nil {
		primary = best(secondary)
	}
	if secondary == nil {
		secondary = best(primary)
	}
	return primary, secondary
}

// networkKey identifies the network a server sends from: servers behind the
// same router share an egress address. IPv6 hosts each get their own address
// inside the site's prefix, so they are grouped by /64. Blank when unknown —
// an unknown network is never "the same" as anything.
func networkKey(v shared.VPS) string {
	ip := v.PublicIP
	if ip == "" && v.IsWireGuard() {
		if h, _, err := net.SplitHostPort(v.WGEndpoint); err == nil {
			ip = h
		}
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return ""
	}
	addr = addr.Unmap()
	if addr.Is6() {
		p, err := addr.Prefix(64)
		if err != nil {
			return ""
		}
		return p.String()
	}
	return addr.String()
}

func sameNetwork(a, b shared.VPS) bool {
	ka, kb := networkKey(a), networkKey(b)
	return ka != "" && ka == kb
}

// SyncWatchers pushes the current election to the fleet: full config to the
// pair, a disable to everyone else. Idempotent — runs on a timer, on config
// change, and when an agent (re)connects.
func (w *WebhookService) SyncWatchers() {
	if !w.syncMu.TryLock() {
		return
	}
	defer w.syncMu.Unlock()

	primary, secondary := w.Elect()
	targets := w.Targets()
	peers := []shared.WatchdogPeer{}
	for _, v := range w.store.ListVPS() {
		host := watchdogHost(v)
		if v.Status == shared.VPSPending || host == "" {
			continue
		}
		port := v.AgentPort
		if port == 0 {
			port = shared.DefaultAgentPort
		}
		peers = append(peers, shared.WatchdogPeer{ID: v.ID, Name: v.Name, Host: host, AgentPort: port})
	}
	primaryID := ""
	if primary != nil {
		primaryID = primary.ID
	}
	w.mu.Lock()
	w.pushed = pairKey(primary, secondary)
	w.mu.Unlock()
	for _, v := range w.store.ListVPS() {
		if !w.agentHub.Connected(v.ID) {
			continue
		}
		role := ""
		enabled := false
		if primary != nil && v.ID == primary.ID {
			role, enabled = "primary", true
		} else if secondary != nil && v.ID == secondary.ID {
			role, enabled = "secondary", true
		}
		wc := shared.WatchdogConfig{Enabled: false, SelfID: v.ID}
		if enabled && len(targets) > 0 {
			wc.Enabled = true
			wc.Role = role
			wc.PrimaryID = primaryID
			wc.Webhooks = targets
			wc.Peers = peers
		}
		body, _ := json.Marshal(wc)
		_, code, err := w.agentHub.Request(v.ID, "POST", "/api/watchdog/config", body, watchdogPushBudget)
		if err != nil || code < 200 || code >= 300 {
			log.Printf("webhooks: push to %s failed: %v (code %d)", v.Name, err, code)
		}
	}
}

func pairKey(primary, secondary *shared.VPS) string {
	k := ""
	if primary != nil {
		k = primary.ID
	}
	k += "|"
	if secondary != nil {
		k += secondary.ID
	}
	return k
}

// errNoWatcher means no watcher took the message. Nothing is sent from this
// computer in that case: its own view of the fleet is exactly what the
// watchers are there to double-check.
var errNoWatcher = errors.New("no fleet watcher reachable — nothing sent")

// deliver hands one message to the primary watcher, then the secondary.
// Returns the route used; suppressed is set when the watcher checked the
// alert and found it untrue from its side (reason says why).
func (w *WebhookService) deliver(msg shared.WebhookMessage) (via string, suppressed string, err error) {
	if len(w.Targets()) == 0 {
		return "", "", nil // configured nowhere — nothing to do
	}
	primary, secondary := w.Elect()
	w.mu.Lock()
	stale := w.pushed != pairKey(primary, secondary)
	w.mu.Unlock()
	if stale {
		// The pair changed since the last push — typically because a
		// watcher is the server that just went down. With no direct path
		// from this computer any more, the new watcher must hold the
		// targets before it is asked to send.
		w.SyncWatchers()
	}
	body, _ := json.Marshal(msg)
	for _, cand := range []struct {
		role string
		vps  *shared.VPS
	}{{"primary", primary}, {"secondary", secondary}} {
		if cand.vps == nil {
			continue
		}
		resp, code, err := w.agentHub.Request(cand.vps.ID, "POST", "/api/watchdog/send", body, watchdogSendBudget)
		if err == nil && code >= 200 && code < 300 {
			via = "watcher " + cand.vps.Name + " (" + cand.role + ")"
			// Agents before 2.2 answer {"ok":true} and always send.
			var res struct {
				Sent   *bool  `json:"sent"`
				Reason string `json:"reason"`
			}
			if json.Unmarshal(resp, &res) == nil && res.Sent != nil && !*res.Sent {
				return via, res.Reason, nil
			}
			return via, "", nil
		}
		log.Printf("webhooks: %s watcher %s failed: %v (code %d)", cand.role, cand.vps.Name, err, code)
	}
	return "", "", errNoWatcher
}

// SendTest delivers a test message down the real path and reports the route.
func (w *WebhookService) SendTest() (string, error) {
	if len(w.Targets()) == 0 {
		return "", nil
	}
	via, _, err := w.deliver(shared.WebhookMessage{
		Title:    "Beacle test notification",
		Body:     "Webhooks are wired up. Alerts will arrive here.",
		Severity: "info",
	})
	return via, err
}

func stringNormalize(s string) string {
	switch s {
	case "Discord", "DISCORD":
		return shared.WebhookDiscord
	case "Ntfy", "NTFY":
		return shared.WebhookNtfy
	case "Telegram", "TELEGRAM":
		return shared.WebhookTelegram
	default:
		return s
	}
}

// watchdogHost is the address a fleet watcher pings. WireGuard servers have
// no Tailscale IP, so the public address (or the handshake endpoint) is the
// only thing that can answer from another VPS.
func watchdogHost(v shared.VPS) string {
	if v.IsWireGuard() {
		if v.PublicIP != "" {
			return v.PublicIP
		}
		if h, _, err := net.SplitHostPort(v.WGEndpoint); err == nil {
			return h
		}
	}
	return v.Host
}
