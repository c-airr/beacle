package main

import (
	"encoding/json"
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
// primary sends peer-down and backend-down notices; the secondary only acts
// while the primary itself is unreachable, so nothing is ever announced
// twice. While the tunnel is up the backend owns all alerting and the loop
// merely tracks state — a notice is only ever sent by one side.
//
// Peers are probed over Tailscale: TCP to SSH first, ICMP ping as the
// fallback, so a host with a closed SSH port still reads as up.

const (
	watchdogTick      = time.Minute
	watchdogDownAfter = 3 // consecutive failed ticks before a peer reads as down
	watchdogBackoff   = 5 * time.Minute
	peerDialTimeout   = 5 * time.Second
)

type tunnelState interface{ isConnected() bool }

type watchdog struct {
	mu       sync.Mutex
	cfg      shared.WatchdogConfig
	down     map[string]int  // peer id -> consecutive failures
	announced map[string]bool // peer id -> down notice sent
	backendDownSince *time.Time
	backendNoticed   bool
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
		if err := shared.SendWebhook(t, msg); err != nil {
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
		wd.onTunnelUp(wc)
		// Track peers silently so a backend outage starts from warm state,
		// but never announce while the backend owns alerting.
		wd.probePeers(wc, false)
		return
	}
	wd.onTunnelDown(wc)
	wd.probePeers(wc, true)
}

func (w *watchdog) onTunnelUp(wc shared.WatchdogConfig) {
	w.mu.Lock()
	downSince := w.backendDownSince
	noticed := w.backendNoticed
	w.backendDownSince = nil
	w.backendNoticed = false
	allow := w.allowedToSendLocked(wc)
	w.mu.Unlock()
	if downSince != nil && noticed && allow {
		_ = w.sendAll(shared.WebhookMessage{
			Title:    "[info] Beacle backend recovered",
			Body:     fmt.Sprintf("Tunnel is back after %s. Fleet supervision resumes from the panel.", time.Since(*downSince).Round(time.Minute)),
			Severity: "info",
		})
	}
}

func (w *watchdog) onTunnelDown(wc shared.WatchdogConfig) {
	w.mu.Lock()
	if w.backendDownSince == nil {
		now := time.Now()
		w.backendDownSince = &now
	}
	quiet := time.Since(*w.backendDownSince)
	noticed := w.backendNoticed
	allow := w.allowedToSendLocked(wc)
	w.mu.Unlock()
	if quiet < watchdogBackoff || noticed || !allow {
		return
	}
	err := w.sendAll(shared.WebhookMessage{
		Title:    "[critical] Beacle backend offline",
		Body:     fmt.Sprintf("No tunnel for %s. Watchers on the fleet keep supervising peers.", quiet.Round(time.Minute)),
		Severity: "critical",
	})
	if err != nil {
		// Do not latch: without delivery nobody knows, so retry next tick.
		log.Printf("watchdog: backend-down notice failed: %v", err)
		return
	}
	w.mu.Lock()
	w.backendNoticed = true
	w.mu.Unlock()
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
	type result struct {
		peer shared.WatchdogPeer
		up   bool
	}
	results := make(chan result, len(wc.Peers))
	for _, p := range wc.Peers {
		if p.ID == wc.SelfID {
			continue
		}
		go func(peer shared.WatchdogPeer) {
			results <- result{peer, peerUp(peer.Host)}
		}(p)
	}
	for i := 0; i < cap(results); i++ {
		r := <-results
		w.mu.Lock()
		if r.up {
			wasAnnounced := w.announced[r.peer.ID]
			w.down[r.peer.ID] = 0
			w.announced[r.peer.ID] = false
			allow := w.allowedToSendLocked(wc)
			w.mu.Unlock()
			if wasAnnounced && announce && allow {
				_ = w.sendAll(shared.WebhookMessage{
					Title:    "[info] " + r.peer.Name + " reachable again",
					Body:     "Peer answers probes.",
					Severity: "info",
				})
			}
			continue
		}
		w.down[r.peer.ID]++
		failures := w.down[r.peer.ID]
		already := w.announced[r.peer.ID]
		allow := w.allowedToSendLocked(wc)
		w.mu.Unlock()
		if announce && !already && failures >= watchdogDownAfter && allow {
			err := w.sendAll(shared.WebhookMessage{
				Title:    "[critical] " + r.peer.Name + " unreachable",
				Body:     fmt.Sprintf("No answer on %s for %d minutes (backend tunnel down — reported by fleet watcher).", r.peer.Host, failures),
				Severity: "critical",
			})
			if err != nil {
				log.Printf("watchdog: peer-down notice failed: %v", err)
				continue
			}
			w.mu.Lock()
			w.announced[r.peer.ID] = true
			w.mu.Unlock()
		}
	}
}
