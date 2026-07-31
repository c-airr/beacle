package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"beacle/shared"
)

// registerAgent matches or creates a VPS entry for an agent (WS register frame).
// rawToken is the bearer the agent presented, even when it matches nothing in
// the registry — that case means the panel lost its state, not that the agent
// is untrusted, so the entry is adopted back instead of rejected.
func (s *Server) registerAgent(req shared.RegisterRequest, remoteIP, rawToken string, tokenEntry *VPSEntry) (*VPSEntry, shared.RegisterResponse, error) {
	host := req.TailscaleIP
	if host == "" {
		host = remoteIP
	}
	tsName := req.TailscaleName
	if tsName == "" {
		tsName = req.Hostname
	}
	publicIP := req.PublicIP

	applyOnline := func(e *VPSEntry) {
		e.VPS.Status = shared.VPSOnline
		e.VPS.LastSeen = time.Now().UTC()
		e.VPS.AgentVer = req.AgentVersion
		if req.AgentPort > 0 {
			e.VPS.AgentPort = req.AgentPort
		}
		if e.VPS.Host == "" && host != "" {
			e.VPS.Host = host
		}
		if tsName != "" {
			e.VPS.TailscaleName = tsName
		}
		if host != "" {
			e.VPS.Host = host
		}
		applyPublicIPGeo(e, publicIP)
	}

	ackFor := func(entry *VPSEntry) shared.RegisterResponse {
		return shared.RegisterResponse{
			OK:    "registered",
			VPSID: entry.VPS.ID,
			// Always return token so a reinstalled agent can persist credentials again.
			Token: entry.AgentToken,
		}
	}

	if tokenEntry != nil {
		updated := s.store.UpdateVPS(tokenEntry.VPS.ID, applyOnline)
		return updated, ackFor(updated), nil
	}

	// Returning agent without Authorization: match by VPS ID already in config.
	if req.VPSID != "" {
		if entry := s.store.GetVPS(req.VPSID); entry != nil && entry.AgentToken != "" {
			updated := s.store.UpdateVPS(entry.VPS.ID, applyOnline)
			return updated, ackFor(updated), nil
		}
	}

	pending := s.store.FindPendingByTailscale(tsName, host)
	if pending == nil {
		// Reclaim offline VPS after agent lost local token (reinstall / wiped config).
		pending = s.store.FindByTailscale(tsName, host)
	}
	if pending == nil {
		// The agent already holds credentials from an earlier registration but
		// the registry no longer knows them (state.json reset / restored from a
		// backup / panel reinstalled). Adopt it back under its own ID and token
		// rather than leaving a healthy agent permanently rejected.
		if rawToken != "" || req.VPSID != "" {
			entry := s.store.AdoptVPS(req.VPSID, rawToken, req.Hostname, host, tsName, req.AgentVersion)
			entry = s.store.UpdateVPS(entry.VPS.ID, applyOnline)
			log.Printf("adopted agent %s (%s) — was missing from registry", entry.VPS.Name, entry.VPS.ID)
			s.logAction(entry.VPS, "vps_adopt", "Agent re-adopted with existing credentials", true)
			return entry, ackFor(entry), nil
		}
		return nil, shared.RegisterResponse{}, fmt.Errorf("no matching VPS — add this server in Beacle first")
	}
	entry := s.store.UpdateVPS(pending.VPS.ID, func(e *VPSEntry) {
		if e.AgentToken == "" {
			e.AgentToken = newToken()
		}
		applyOnline(e)
	})
	s.logAction(entry.VPS, "vps_register", "Agent connected via WebSocket", true)
	return entry, ackFor(entry), nil
}

func agentRemoteIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
