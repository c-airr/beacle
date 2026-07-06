package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"time"
)

type pairingEntry struct {
	Token     string    `json:"token"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
	Used      bool      `json:"used"`
}

func (s *Store) createPairingToken() *pairingEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state.Pairing == nil {
		s.state.Pairing = map[string]*pairingEntry{}
	}
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	tok := hex.EncodeToString(b)
	e := &pairingEntry{
		Token:     tok,
		CreatedAt: time.Now().UTC(),
		ExpiresAt: time.Now().UTC().Add(24 * time.Hour),
	}
	s.state.Pairing[tok] = e
	s.persistLocked()
	return e
}

func (s *Store) consumePairingToken(tok string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.state.Pairing[tok]
	if !ok || e.Used || time.Now().After(e.ExpiresAt) {
		return false
	}
	e.Used = true
	s.persistLocked()
	return true
}

func (s *Store) pairingValid(tok string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.state.Pairing[tok]
	return ok && !e.Used && time.Now().Before(e.ExpiresAt)
}

func (s *Server) installBaseURL() string {
	if u := s.store.HubURL(); u != "" {
		return u
	}
	return s.baseURL
}

func (s *Server) handleCreatePairingToken(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	e := s.store.createPairingToken()
	base := s.installBaseURL()
	writeJSON(w, http.StatusOK, map[string]string{
		"token":            e.Token,
		"install_command":  fmt.Sprintf("curl -sSL %s/install/%s | bash", base, e.Token),
		"set_command":      fmt.Sprintf("beacle set %s", e.Token),
		"expires_at":       e.ExpiresAt.Format(time.RFC3339),
	})
}

func (s *Server) handleInstallScriptToken(w http.ResponseWriter, r *http.Request) {
	tok := r.PathValue("token")
	if !s.store.pairingValid(tok) {
		writeErr(w, http.StatusNotFound, "invalid or expired pairing token")
		return
	}
	base := s.installBaseURL()
	w.Header().Set("Content-Type", "text/x-shellscript")
	_, _ = w.Write([]byte(installScriptWithToken(base, tok)))
}

func (s *Server) handlePairingBootstrap(w http.ResponseWriter, r *http.Request) {
	tok := r.PathValue("token")
	if !s.store.pairingValid(tok) {
		writeErr(w, http.StatusNotFound, "invalid or expired pairing token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"backend_url":    s.installBaseURL(),
		"pairing_token":  tok,
		"hub_url":        s.store.HubURL(),
	})
}

func (s *Server) handleHubStatus(w http.ResponseWriter, r *http.Request) {
	hubID, hubURL := s.store.HubInfo()
	writeJSON(w, http.StatusOK, map[string]any{
		"hub_vps_id": hubID,
		"hub_url":    hubURL,
		"active":     hubID != "",
		"message":    s.store.HubMessage(),
	})
}
