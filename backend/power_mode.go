package main

import (
	"encoding/json"
	"net/http"

	"beacle/shared"
)

// UI power mode: backend tells agents active/eco/sleep; agents own all intervals.
func (s *Server) agentPowerMode() shared.PowerMode {
	s.uiPowerMu.RLock()
	defer s.uiPowerMu.RUnlock()
	if s.uiPowerMode == "" {
		return shared.PowerModeActive
	}
	return s.uiPowerMode
}

func (s *Server) setUIPowerMode(mode shared.PowerMode) {
	if mode == "" {
		mode = shared.PowerModeActive
	}
	s.uiPowerMu.Lock()
	changed := s.uiPowerMode != mode
	s.uiPowerMode = mode
	s.uiPowerMu.Unlock()
	if !changed {
		return
	}
	s.agentHub.SetPowerMode(mode)
	if mode == shared.PowerModeActive {
		s.agentHub.RequestRefreshAll()
	}
}

func (s *Server) handleUIPowerMode(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST required")
		return
	}
	var body struct {
		Mode string `json:"mode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	switch shared.PowerMode(body.Mode) {
	case shared.PowerModeActive, shared.PowerModeEco, shared.PowerModeSleep:
	default:
		writeErr(w, http.StatusBadRequest, "mode must be active, eco, or sleep")
		return
	}
	s.setUIPowerMode(shared.PowerMode(body.Mode))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "mode": body.Mode})
}
