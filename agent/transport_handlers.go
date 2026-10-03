package main

import (
	"encoding/json"
	"net/http"

	"beacle/shared"
)

func (s *APIServer) handleTransportWireGuard(w http.ResponseWriter, r *http.Request) {
	var req shared.TransportSwitchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if req.Transport != shared.TransportWireGuard || req.Join == "" {
		jsonErr(w, http.StatusBadRequest, "join token required")
		return
	}
	var switchErr error
	if err := transport.update(s.cfg, func(c *Config) bool {
		switchErr = applySwitchToWireGuard(c, req.Join)
		return switchErr == nil
	}); err != nil {
		jsonErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if switchErr != nil {
		jsonErr(w, http.StatusBadRequest, switchErr.Error())
		return
	}
	// Before reconnecting: the panel starts sending to this port right away,
	// and this path runs no install script that could have opened it.
	ensureWireGuardPort(s.cfg)
	if s.kickSession != nil {
		s.kickSession()
	}
	jsonOut(w, http.StatusOK, transportStatus(s.cfg))
}

func (s *APIServer) handleTransportTailscale(w http.ResponseWriter, r *http.Request) {
	var req shared.TransportSwitchRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonErr(w, http.StatusBadRequest, "bad json")
		return
	}
	var switchErr error
	if err := transport.update(s.cfg, func(c *Config) bool {
		switchErr = applySwitchToTailscale(c, req.BackendURL)
		return switchErr == nil
	}); err != nil {
		jsonErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if switchErr != nil {
		jsonErr(w, http.StatusBadRequest, switchErr.Error())
		return
	}
	if s.kickSession != nil {
		s.kickSession()
	}
	jsonOut(w, http.StatusOK, transportStatus(s.cfg))
}

func (s *APIServer) handleTransportStatus(w http.ResponseWriter, r *http.Request) {
	jsonOut(w, http.StatusOK, transportStatus(s.cfg))
}

func (s *APIServer) handlePublicIPs(w http.ResponseWriter, r *http.Request) {
	jsonOut(w, http.StatusOK, map[string]string{"public_ip": fetchPublicIP()})
}

// handleRemoveTailscale uninstalls Tailscale from the host for a server that
// has moved to WireGuard and no longer needs it. Only once the tunnel is
// confirmed: while the switch is on trial, Tailscale is the way back.
func (s *APIServer) handleRemoveTailscale(w http.ResponseWriter, r *http.Request) {
	var ready bool
	_ = transport.update(s.cfg, func(c *Config) bool {
		ready = c.IsWireGuard() && c.FallbackBackendURL == ""
		return false
	})
	if !ready {
		jsonErr(w, http.StatusConflict, "WireGuard is not confirmed on this server yet — Tailscale is still its way back to the panel")
		return
	}
	out, err := removeTailscale(r.Context())
	if err != nil {
		jsonOut(w, http.StatusInternalServerError, map[string]any{"error": err.Error(), "output": out})
		return
	}
	jsonOut(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}
