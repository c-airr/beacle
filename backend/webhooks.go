package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"beacle/shared"
)

// Outgoing notifications. Delivery normally runs from the fleet itself: the
// backend elects the two most stable online VPSes as watchers (primary +
// secondary) and pushes them the webhook targets plus the peer list. Every
// alert is then sent by a watcher over the command tunnel; only when neither
// answers does the backend POST directly. The watchers also supervise the
// fleet on their own while the tunnel is down (see agent/watchdog.go), so a
// dead panel still means notified phones rather than silent servers.
//
// Stability is sample coverage over the last 24h — a host that flapped has
// gaps — with fleet seniority as the tiebreak. When the backend itself was
// off most of the day every host ties and the two oldest win, which is the
// sanest answer available: the longest-proven boxes.

const (
	watcherSyncEvery   = 5 * time.Minute
	watcherStability   = 24 * time.Hour
	watchdogPushBudget = 15 * time.Second
)

type WebhookService struct {
	mu      sync.Mutex
	path    string
	targets []shared.WebhookTarget

	store    *Store
	agentHub *AgentHub
	history  *History

	queue  chan shared.WebhookMessage
	syncMu sync.Mutex // syncWatchers runs alone; overlapping ticks skip
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
		var saved struct {
			Targets []shared.WebhookTarget `json:"targets"`
		}
		if json.Unmarshal(raw, &saved) == nil {
			w.targets = saved.Targets
		}
	}
	return w
}

func (w *WebhookService) persistLocked() {
	data, err := json.MarshalIndent(map[string]any{"targets": w.targets}, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(w.path, data, 0o600)
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
	w.persistLocked()
	w.mu.Unlock()
	go w.SyncWatchers()
	return nil
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
		via, err := w.deliver(msg)
		if err != nil {
			log.Printf("webhooks: %q failed: %v", msg.Title, err)
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

// WatcherPair is the current election result for the panel.
type WatcherPair struct {
	Primary   *shared.VPS `json:"primary,omitempty"`
	Secondary *shared.VPS `json:"secondary,omitempty"`
}

// Elect ranks online VPSes by stability. Empty when nobody is online.
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
	if len(cands) == 0 {
		return nil, nil
	}
	since := time.Now().Add(-watcherStability)
	coverage := map[string]int{}
	for _, v := range cands {
		coverage[v.ID] = len(w.history.Query(v.ID, since, time.Now()))
	}
	sort.Slice(cands, func(i, j int) bool {
		if coverage[cands[i].ID] != coverage[cands[j].ID] {
			return coverage[cands[i].ID] > coverage[cands[j].ID]
		}
		if !cands[i].CreatedAt.Equal(cands[j].CreatedAt) {
			return cands[i].CreatedAt.Before(cands[j].CreatedAt)
		}
		return cands[i].ID < cands[j].ID
	})
	primary = &cands[0]
	if len(cands) > 1 {
		secondary = &cands[1]
	}
	return primary, secondary
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
		if v.Status == shared.VPSPending || v.Host == "" {
			continue
		}
		peers = append(peers, shared.WatchdogPeer{ID: v.ID, Name: v.Name, Host: v.Host})
	}
	primaryID := ""
	if primary != nil {
		primaryID = primary.ID
	}
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

// deliver sends one message: primary watcher, then secondary, then direct
// from the backend as the last resort. Returns the path used.
func (w *WebhookService) deliver(msg shared.WebhookMessage) (string, error) {
	if len(w.Targets()) == 0 {
		return "", nil // configured nowhere — nothing to do
	}
	primary, secondary := w.Elect()
	body, _ := json.Marshal(msg)
	for _, cand := range []struct {
		role string
		vps  *shared.VPS
	}{{"primary", primary}, {"secondary", secondary}} {
		if cand.vps == nil {
			continue
		}
		_, code, err := w.agentHub.Request(cand.vps.ID, "POST", "/api/watchdog/send", body, watchdogPushBudget)
		if err == nil && code >= 200 && code < 300 {
			return "watcher " + cand.vps.Name + " (" + cand.role + ")", nil
		}
		log.Printf("webhooks: %s watcher %s failed: %v (code %d)", cand.role, cand.vps.Name, err, code)
	}
	// Last resort: the backend's own connection. This is also the only path
	// when no agent is online at all.
	var firstErr error
	sent := 0
	for _, t := range w.Targets() {
		if err := shared.SendWebhook(t, msg); err != nil {
			log.Printf("webhooks: direct %s failed: %v", t.Kind, err)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		sent++
	}
	if sent == 0 && firstErr != nil {
		return "", firstErr
	}
	return "backend direct", nil
}

// SendTest delivers a test message down the real path and reports the route.
func (w *WebhookService) SendTest() (string, error) {
	if len(w.Targets()) == 0 {
		return "", nil
	}
	return w.deliver(shared.WebhookMessage{
		Title:    "Beacle test notification",
		Body:     "Webhooks are wired up. Alerts will arrive here.",
		Severity: "info",
	})
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
