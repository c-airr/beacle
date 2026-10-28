package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"

	"beacle/shared"
)

// wgPeerRecord is what the panel needs to recognise a WireGuard server again
// after state.json is lost: the peer key decides who an agent is, so the
// registry entry can be rebuilt from this and the agent reconnects as itself.
type wgPeerRecord struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Host       string `json:"host,omitempty"`
	Transport  string `json:"transport,omitempty"`
	Endpoint   string `json:"endpoint,omitempty"`
	TunnelIP   string `json:"tunnel_ip"`
	PublicKey  string `json:"public_key"`
	PSK        string `json:"psk,omitempty"`
	AgentToken string `json:"agent_token,omitempty"`
	Pending    bool   `json:"pending,omitempty"`
}

func (s *Store) peersPath() string { return filepath.Join(filepath.Dir(s.path), "wg-peers.json") }

// restoreWGPeers puts back servers the registry lost but the peers file still
// knows. Runs before the first write, which would mirror the loss into the file.
func (s *Store) restoreWGPeers() {
	b, err := os.ReadFile(s.peersPath())
	if err != nil {
		return
	}
	var recs []wgPeerRecord
	if json.Unmarshal(b, &recs) != nil {
		return
	}
	for _, r := range recs {
		if r.ID == "" || r.PublicKey == "" || r.TunnelIP == "" || s.state.VPS[r.ID] != nil {
			continue
		}
		e := &VPSEntry{
			VPS: shared.VPS{
				ID: r.ID, Name: r.Name, Host: r.Host, Transport: r.Transport,
				WGEndpoint: r.Endpoint, WGTunnelIP: r.TunnelIP, WGPublicKey: r.PublicKey,
				Weight: 1, Status: shared.VPSOffline, AgentPort: shared.DefaultAgentPort,
				CreatedAt: time.Now().UTC(), LastSeen: time.Now().UTC(),
			},
			WGPresharedKey: r.PSK,
			AgentToken:     r.AgentToken,
		}
		if r.Pending {
			e.VPS.Status = shared.VPSPending
		}
		s.state.VPS[r.ID] = e
		log.Printf("store: restored WireGuard server %s (%s) from wg-peers.json", r.Name, r.ID)
	}
}

// writePeersLocked mirrors the registry's WireGuard servers into the peers
// file; skipped when nothing in it changed, since this runs on every flush.
func (s *Store) writePeersLocked() {
	recs := []wgPeerRecord{}
	for _, e := range s.state.VPS {
		if !e.HasWireGuardPeer() {
			continue
		}
		recs = append(recs, wgPeerRecord{
			ID: e.VPS.ID, Name: e.VPS.Name, Host: e.VPS.Host, Transport: e.VPS.Transport,
			Endpoint: e.VPS.WGEndpoint, TunnelIP: e.VPS.WGTunnelIP, PublicKey: e.VPS.WGPublicKey,
			PSK: e.WGPresharedKey, AgentToken: e.AgentToken, Pending: e.VPS.Status == shared.VPSPending,
		})
	}
	b, err := json.MarshalIndent(recs, "", "  ")
	if err != nil || bytes.Equal(b, s.lastPeers) {
		return
	}
	tmp := s.peersPath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		log.Printf("store: write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, s.peersPath()); err != nil {
		log.Printf("store: replace %s: %v", s.peersPath(), err)
		return
	}
	s.lastPeers = b
}
