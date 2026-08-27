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
	"sync/atomic"
	"time"

	"beacle/shared"
)

// VPSEntry is the persisted record for one VPS (registry + secret token).
type VPSEntry struct {
	VPS        shared.VPS `json:"vps"`
	AgentToken string     `json:"agent_token"`
}

type persistedState struct {
	VPS     map[string]*VPSEntry       `json:"vps"`
	Links   map[string]*shared.VPSLink `json:"links"`
	Alerts  []shared.Alert             `json:"alerts"`
	Actions []shared.ActionLog         `json:"actions"`
}

// Store keeps the registry on disk (JSON file) and live snapshots in memory.
type Store struct {
	mu        sync.RWMutex
	path      string
	state     persistedState
	snapshots map[string]*shared.VPSSnapshot
	dirty     atomic.Bool
}

func NewStore(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	s := &Store{
		path: filepath.Join(dataDir, "state.json"),
		state: persistedState{
			VPS:   map[string]*VPSEntry{},
			Links: map[string]*shared.VPSLink{},
		},
		snapshots: map[string]*shared.VPSSnapshot{},
	}
	if b, err := os.ReadFile(s.path); err == nil {
		_ = json.Unmarshal(b, &s.state)
	}
	if s.state.VPS == nil {
		s.state.VPS = map[string]*VPSEntry{}
	}
	if s.state.Links == nil {
		s.state.Links = map[string]*shared.VPSLink{}
	}
	// No agent socket survives a backend restart, so the persisted status is
	// meaningless here: trusting it would show a server as online with no
	// snapshot behind it until the offline watcher caught up. Every non-pending
	// VPS starts offline and is flipped online by its first WebSocket frame.
	for _, e := range s.state.VPS {
		if e.VPS.Status != shared.VPSPending {
			e.VPS.Status = shared.VPSOffline
		}
	}
	return s, nil
}

// Persist writes the registry out immediately (shutdown path).
func (s *Store) Persist() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dirty.Store(false)
	s.writeLocked()
}

// FlushLoop drains deferred writes at a bounded rate. Call once at startup.
func (s *Store) FlushLoop() {
	for range time.Tick(3 * time.Second) {
		if !s.dirty.Swap(false) {
			continue
		}
		s.mu.Lock()
		s.writeLocked()
		s.mu.Unlock()
	}
}

// touchLocked defers a write instead of doing it inline. Every agent frame
// bumps LastSeen — a few times per second per VPS — and re-serializing the
// whole registry under the write lock that often stalled snapshot fan-out for
// no benefit: none of those fields matter across a restart.
func (s *Store) touchLocked() { s.dirty.Store(true) }

// persistLocked writes structural changes (identity, tokens, links, history)
// that must survive an unclean exit.
func (s *Store) persistLocked() {
	s.dirty.Store(false)
	s.writeLocked()
}

func (s *Store) writeLocked() {
	b, err := json.MarshalIndent(&s.state, "", "  ")
	if err != nil {
		log.Printf("store: encode state: %v", err)
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		log.Printf("store: write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		log.Printf("store: replace %s: %v", s.path, err)
	}
}

func newID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func newToken() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// --- VPS registry ----------------------------------------------------------

// CreateVPS adds a server from Tailscale (onboarding). Agent connects later.
func (s *Store) CreateVPS(name, tailscaleName, tailscaleIP string) *VPSEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.state.VPS {
		if e.VPS.TailscaleName == tailscaleName || (tailscaleIP != "" && e.VPS.Host == tailscaleIP) {
			c := *e
			return &c
		}
	}
	entry := &VPSEntry{
		VPS: shared.VPS{
			ID:            newID(),
			Name:          name,
			Host:          tailscaleIP,
			TailscaleName: tailscaleName,
			Weight:        1,
			Status:        shared.VPSPending,
			AgentPort:     shared.DefaultAgentPort,
			CreatedAt:     time.Now().UTC(),
			LastSeen:      time.Now().UTC(),
		},
	}
	s.state.VPS[entry.VPS.ID] = entry
	s.persistLocked()
	c := *entry
	return &c
}

// FindPendingByTailscale matches a pre-added VPS waiting for its agent.
func (s *Store) FindPendingByTailscale(name, ip string) *VPSEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, e := range s.state.VPS {
		if e.AgentToken != "" {
			continue
		}
		if name != "" && e.VPS.TailscaleName == name {
			c := *e
			return &c
		}
		if ip != "" && e.VPS.Host == ip {
			c := *e
			return &c
		}
	}
	return nil
}

// FindByTailscale matches any known VPS by Tailscale hostname or IP.
// Used to reclaim an offline VPS after agent reinstall (lost local token).
func (s *Store) FindByTailscale(name, ip string) *VPSEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, e := range s.state.VPS {
		if name != "" && e.VPS.TailscaleName == name {
			c := *e
			return &c
		}
		if ip != "" && e.VPS.Host == ip {
			c := *e
			return &c
		}
	}
	return nil
}

// AutoRegisterVPS creates a VPS entry for a first-time agent registration.
// This is the ONLY way VPS entries come into existence - there is no manual
// creation from the UI.
func (s *Store) AutoRegisterVPS(hostname, host string, agentPort int, agentVersion string) *VPSEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	if agentPort <= 0 {
		agentPort = shared.DefaultAgentPort
	}
	name := hostname
	if name == "" {
		name = host
	}
	entry := &VPSEntry{
		VPS: shared.VPS{
			ID:        newID(),
			Name:      name,
			Host:      host,
			Weight:    1,
			Status:    shared.VPSOnline,
			AgentPort: agentPort,
			AgentVer:  agentVersion,
			CreatedAt: time.Now().UTC(),
			LastSeen:  time.Now().UTC(),
		},
		AgentToken: newToken(),
	}
	s.state.VPS[entry.VPS.ID] = entry
	s.persistLocked()
	c := *entry
	return &c
}

// AdoptVPS re-creates an entry for an agent that still holds credentials the
// registry lost (state.json reset, restored backup, reinstalled panel). The
// agent's own ID and token are kept, so it keeps reconnecting with what it
// already has on disk instead of needing a reinstall.
func (s *Store) AdoptVPS(vpsID, token, name, host, tailscaleName, agentVer string) *VPSEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	if vpsID == "" {
		vpsID = newID()
	}
	if token == "" {
		token = newToken()
	}
	if name == "" {
		name = tailscaleName
	}
	if name == "" {
		name = host
	}
	if e, ok := s.state.VPS[vpsID]; ok {
		c := *e
		return &c
	}
	entry := &VPSEntry{
		VPS: shared.VPS{
			ID:            vpsID,
			Name:          name,
			Host:          host,
			TailscaleName: tailscaleName,
			Weight:        1,
			Status:        shared.VPSOnline,
			AgentPort:     shared.DefaultAgentPort,
			AgentVer:      agentVer,
			CreatedAt:     time.Now().UTC(),
			LastSeen:      time.Now().UTC(),
		},
		AgentToken: token,
	}
	s.state.VPS[vpsID] = entry
	s.persistLocked()
	c := *entry
	return &c
}

func (s *Store) UpdateVPS(id string, fn func(*VPSEntry)) *VPSEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.state.VPS[id]
	if !ok {
		return nil
	}
	fn(e)
	s.touchLocked()
	// Callers read the result after the lock is gone — hand out a copy so a
	// concurrent frame from the same agent cannot tear it.
	c := *e
	return &c
}

func (s *Store) DeleteVPS(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.state.VPS[id]; !ok {
		return false
	}
	delete(s.state.VPS, id)
	delete(s.snapshots, id)
	for lid, l := range s.state.Links {
		if l.FromVPSID == id || l.ToVPSID == id {
			delete(s.state.Links, lid)
		}
	}
	s.persistLocked()
	return true
}

func (s *Store) GetVPS(id string) *VPSEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if e, ok := s.state.VPS[id]; ok {
		c := *e
		return &c
	}
	return nil
}

// FindByToken authenticates an agent request.
func (s *Store) FindByToken(token string) *VPSEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, e := range s.state.VPS {
		if e.AgentToken != "" && e.AgentToken == token {
			c := *e
			return &c
		}
	}
	return nil
}

// ListVPS returns every registered server in a stable order.
//
// The registry is a map, and Go randomises map iteration on purpose, so this
// used to hand back a different order on every call — the server list, and the
// dropdowns built from it, reshuffled themselves on every refresh.
//
// Sorted by name so a server can be found where it was last time, with the id
// as a tiebreak so identically named hosts still land in a fixed order.
func (s *Store) ListVPS() []shared.VPS {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]shared.VPS, 0, len(s.state.VPS))
	for _, e := range s.state.VPS {
		out = append(out, e.VPS)
	}
	sortVPS(out)
	return out
}

// sortVPS is the one place the fleet order is decided; the panel mirrors it so
// a list rebuilt from a single update lands the same way as a full refresh.
func sortVPS(list []shared.VPS) {
	sort.Slice(list, func(i, j int) bool {
		return lessVPS(list[i].CreatedAt, list[i].ID, list[j].CreatedAt, list[j].ID)
	})
}

// lessVPS orders servers by when they were added, oldest first.
//
// Insertion order rather than name: a rename would otherwise move a server
// across the list, so the position a reader has learned keeps changing for a
// second reason on top of the map-iteration randomness this replaced. Where a
// server sits should depend on nothing that can be edited.
//
// The id breaks ties — two servers registered in the same instant, and entries
// old enough to predate CreatedAt being recorded, both land in a fixed order
// instead of a random one.
func lessVPS(aAt time.Time, aID string, bAt time.Time, bID string) bool {
	if !aAt.Equal(bAt) {
		return aAt.Before(bAt)
	}
	return aID < bID
}

// --- Snapshots (live, in-memory) -------------------------------------------

func (s *Store) ClearSnapshot(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.snapshots, id)
}

func (s *Store) SetSnapshot(snap *shared.VPSSnapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshots[snap.VPS.ID] = snap
}

func (s *Store) GetSnapshot(id string) *shared.VPSSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snapshots[id]
}

// ListSnapshots returns live snapshots in the same order as ListVPS, for the
// same reason: this is a map too, and the overview is built from it.
func (s *Store) ListSnapshots() []*shared.VPSSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*shared.VPSSnapshot, 0, len(s.snapshots))
	for _, v := range s.snapshots {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool {
		return lessVPS(out[i].VPS.CreatedAt, out[i].VPS.ID, out[j].VPS.CreatedAt, out[j].VPS.ID)
	})
	return out
}

// --- Links -----------------------------------------------------------------

func (s *Store) CreateLink(from, to string) *shared.VPSLink {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, l := range s.state.Links {
		if (l.FromVPSID == from && l.ToVPSID == to) || (l.FromVPSID == to && l.ToVPSID == from) {
			return l
		}
	}
	link := &shared.VPSLink{ID: newID(), FromVPSID: from, ToVPSID: to, Status: "unknown"}
	s.state.Links[link.ID] = link
	s.persistLocked()
	return link
}

func (s *Store) UpdateLink(id string, fn func(*shared.VPSLink)) *shared.VPSLink {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.state.Links[id]
	if !ok {
		return nil
	}
	fn(l)
	s.persistLocked()
	c := *l
	return &c
}

func (s *Store) DeleteLink(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.state.Links[id]; !ok {
		return false
	}
	delete(s.state.Links, id)
	s.persistLocked()
	return true
}

func (s *Store) ListLinks() []shared.VPSLink {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]shared.VPSLink, 0, len(s.state.Links))
	for _, l := range s.state.Links {
		out = append(out, *l)
	}
	return out
}

// --- Alerts ----------------------------------------------------------------

const maxAlerts = 500

func (s *Store) AddAlert(a shared.Alert) shared.Alert {
	s.mu.Lock()
	defer s.mu.Unlock()
	a.ID = newID()
	a.CreatedAt = time.Now().UTC()
	s.state.Alerts = append(s.state.Alerts, a)
	if len(s.state.Alerts) > maxAlerts {
		s.state.Alerts = s.state.Alerts[len(s.state.Alerts)-maxAlerts:]
	}
	s.persistLocked()
	return a
}

// ResolveAlertsFor deletes every open alert for one condition and returns them
// so the caller can tell the UI to drop those rows.
//
// Deleted rather than flagged. A resolved alert is a problem that is over, and
// keeping it turns the list into a log: this store had 159 alerts in it, every
// one of them resolved, mostly a host parked at 90% RAM opening a fresh row
// each time a sample crossed the line. Nobody reads a list like that, which
// makes the real alert underneath it invisible.
//
// The returned rows still carry Resolved so the panel can tell a removal from
// an update — see the alert case in app_state.dart.
func (s *Store) ResolveAlertsFor(vpsID string, t shared.AlertType, key string) []shared.Alert {
	s.mu.Lock()
	defer s.mu.Unlock()
	var changed []shared.Alert
	kept := s.state.Alerts[:0]
	for _, a := range s.state.Alerts {
		if a.Resolved || a.VPSID != vpsID || a.Type != t || a.Key != key {
			kept = append(kept, a)
			continue
		}
		a.Resolved = true
		changed = append(changed, a)
	}
	if len(changed) > 0 {
		s.state.Alerts = kept
		s.persistLocked()
	}
	return changed
}

// PurgeResolvedAlerts drops rows left behind by older builds, which flagged
// resolved alerts instead of removing them. Returns how many went.
func (s *Store) PurgeResolvedAlerts() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.state.Alerts[:0]
	for _, a := range s.state.Alerts {
		if !a.Resolved {
			kept = append(kept, a)
		}
	}
	removed := len(s.state.Alerts) - len(kept)
	if removed > 0 {
		s.state.Alerts = kept
		s.persistLocked()
	}
	return removed
}

// ResolveAlert removes a single alert by id, for the same reason as above.
func (s *Store) ResolveAlert(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Alerts {
		if s.state.Alerts[i].ID != id {
			continue
		}
		s.state.Alerts = append(s.state.Alerts[:i], s.state.Alerts[i+1:]...)
		s.persistLocked()
		return true
	}
	return false
}

func (s *Store) ListAlerts() []shared.Alert {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]shared.Alert, len(s.state.Alerts))
	copy(out, s.state.Alerts)
	return out
}

// --- Action log --------------------------------------------------------------

const maxActions = 300

func (s *Store) AddAction(a shared.ActionLog) shared.ActionLog {
	s.mu.Lock()
	defer s.mu.Unlock()
	a.ID = newID()
	a.CreatedAt = time.Now().UTC()
	s.state.Actions = append(s.state.Actions, a)
	if len(s.state.Actions) > maxActions {
		s.state.Actions = s.state.Actions[len(s.state.Actions)-maxActions:]
	}
	s.persistLocked()
	return a
}

func (s *Store) ListActions() []shared.ActionLog {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]shared.ActionLog, len(s.state.Actions))
	copy(out, s.state.Actions)
	return out
}
