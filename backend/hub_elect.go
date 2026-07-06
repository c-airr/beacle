package main

import (
	"fmt"
	"log"
)

func (s *Store) HubInfo() (vpsID, url string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.HubVPSID, s.state.HubURL
}

func (s *Store) HubURL() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.state.HubURL
}

func (s *Store) HubMessage() string {
	if s.state.HubVPSID != "" {
		return "Hub node active — agents connect outbound to " + s.state.HubURL
	}
	return "No hub node yet. Add a VPS with a public IP (e.g. cloud VPS) to enable agent networking."
}

// TryElectHub picks the first VPS with a public IP as the network hub.
func (s *Store) TryElectHub(vpsID, host string) {
	if !isPublicIP(host) {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.HubVPSID != "" {
		return
	}
	s.state.HubVPSID = vpsID
	s.state.HubURL = fmt.Sprintf("http://%s:8930", host)
	if e, ok := s.state.VPS[vpsID]; ok {
		e.VPS.IsHub = true
		e.VPS.HasPublicIP = true
	}
	s.persistLocked()
	log.Printf("hub elected: vps %s at %s", vpsID, s.state.HubURL)
}

func (s *Store) MarkPublicIP(vpsID, host string) {
	pub := isPublicIP(host)
	s.mu.Lock()
	defer s.mu.Unlock()
	if e, ok := s.state.VPS[vpsID]; ok {
		e.VPS.HasPublicIP = pub
	}
	s.persistLocked()
}
