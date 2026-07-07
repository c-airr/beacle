package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
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
	return s, nil
}

func (s *Store) Persist() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.persistLocked()
}

func (s *Store) persistLocked() {
	b, err := json.MarshalIndent(&s.state, "", "  ")
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err == nil {
		_ = os.Rename(tmp, s.path)
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
			return e
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
	return entry
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
	return entry
}

func (s *Store) UpdateVPS(id string, fn func(*VPSEntry)) *VPSEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.state.VPS[id]
	if !ok {
		return nil
	}
	fn(e)
	s.persistLocked()
	return e
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

func (s *Store) ListVPS() []shared.VPS {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]shared.VPS, 0, len(s.state.VPS))
	for _, e := range s.state.VPS {
		out = append(out, e.VPS)
	}
	return out
}

// --- Snapshots (live, in-memory) -------------------------------------------

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

func (s *Store) ListSnapshots() []*shared.VPSSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*shared.VPSSnapshot, 0, len(s.snapshots))
	for _, v := range s.snapshots {
		out = append(out, v)
	}
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

func (s *Store) ResolveAlert(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.state.Alerts {
		if s.state.Alerts[i].ID == id {
			s.state.Alerts[i].Resolved = true
			s.persistLocked()
			return true
		}
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
