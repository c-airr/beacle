package main

import (
	"fmt"
	"net"
	"net/http"
	"time"

	"beacle/shared"
)

// registerAgent matches or creates a VPS entry for an agent (WS register frame).
func (s *Server) registerAgent(req shared.RegisterRequest, remoteIP string, tokenEntry *VPSEntry) (*VPSEntry, shared.RegisterResponse, error) {
	host := req.TailscaleIP
	if host == "" {
		host = remoteIP
	}
	tsName := req.TailscaleName
	if tsName == "" {
		tsName = req.Hostname
	}
	publicIP := req.PublicIP

	if tokenEntry != nil {
		updated := s.store.UpdateVPS(tokenEntry.VPS.ID, func(e *VPSEntry) {
			e.VPS.Status = shared.VPSOnline
			e.VPS.LastSeen = time.Now().UTC()
			e.VPS.AgentVer = req.AgentVersion
			if req.AgentPort > 0 {
				e.VPS.AgentPort = req.AgentPort
			}
			if e.VPS.Host == "" && host != "" {
				e.VPS.Host = host
			}
			applyPublicIPGeo(e, publicIP)
		})
		return updated, shared.RegisterResponse{
			OK:    "registered",
			VPSID: updated.VPS.ID,
		}, nil
	}

	// Returning agent without Authorization: match by VPS ID already in config.
	if req.VPSID != "" {
		if entry := s.store.GetVPS(req.VPSID); entry != nil && entry.AgentToken != "" {
			updated := s.store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) {
				e.VPS.Status = shared.VPSOnline
				e.VPS.LastSeen = time.Now().UTC()
				e.VPS.AgentVer = req.AgentVersion
				if req.AgentPort > 0 {
					e.VPS.AgentPort = req.AgentPort
				}
				if e.VPS.Host == "" && host != "" {
					e.VPS.Host = host
				}
				applyPublicIPGeo(e, publicIP)
			})
			return updated, shared.RegisterResponse{
				OK:    "registered",
				VPSID: updated.VPS.ID,
			}, nil
		}
	}

	pending := s.store.FindPendingByTailscale(tsName, host)
	if pending == nil {
		return nil, shared.RegisterResponse{}, fmt.Errorf("no matching VPS — add this server in Beacle first")
	}
	entry := s.store.UpdateVPS(pending.VPS.ID, func(e *VPSEntry) {
		if e.AgentToken == "" {
			e.AgentToken = newToken()
		}
		e.VPS.Status = shared.VPSOnline
		e.VPS.LastSeen = time.Now().UTC()
		e.VPS.AgentVer = req.AgentVersion
		e.VPS.Host = host
		e.VPS.TailscaleName = tsName
		if req.AgentPort > 0 {
			e.VPS.AgentPort = req.AgentPort
		}
		applyPublicIPGeo(e, publicIP)
	})
	s.logAction(entry.VPS, "vps_register", "Agent connected via WebSocket", true)
	return entry, shared.RegisterResponse{
		OK:    "registered",
		VPSID: entry.VPS.ID,
		Token: entry.AgentToken,
	}, nil
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
