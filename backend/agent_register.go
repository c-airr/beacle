package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
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
	applyOnline := func(e *VPSEntry) { applyAgentOnline(e, req, host, tsName) }

	if tokenEntry != nil {
		if tokenEntry.VPS.IsWireGuard() {
			// Its token alone does not open it from the Tailscale side — the
			// WireGuard key is the identity, and the switch-back path clears
			// the transport before the agent dials here.
			return nil, shared.RegisterResponse{}, fmt.Errorf("this server is connected over WireGuard")
		}
		updated := s.store.UpdateVPS(tokenEntry.VPS.ID, applyOnline)
		return updated, ackFor(updated), nil
	}

	// Returning agent without Authorization: match by VPS ID already in config.
	if req.VPSID != "" {
		if entry := s.store.GetVPS(req.VPSID); entry != nil && entry.VPS.IsWireGuard() {
			return nil, shared.RegisterResponse{}, fmt.Errorf("this server is connected over WireGuard")
		} else if entry != nil && entry.AgentToken != "" {
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

// registerPinnedAgent registers an agent that arrived through the WireGuard
// tunnel. The peer key already proved which server this is, so there is no
// matching and no adoption: the socket belongs to vpsID or to nobody.
func (s *Server) registerPinnedAgent(req shared.RegisterRequest, vpsID string) (*VPSEntry, shared.RegisterResponse, error) {
	first := false
	entry := s.store.UpdateVPSNow(vpsID, func(e *VPSEntry) {
		if e.AgentToken == "" {
			e.AgentToken = newToken()
		}
		if e.WGAgentKey != "" {
			// The key has been used; from here on the panel cannot hand it
			// out again, so a leaked screenshot of the old command is dead.
			e.WGAgentKey = ""
			first = true
		}
		applyAgentOnline(e, req, "", "")
		// A Tailscale server trialling the switch becomes a WireGuard one
		// the moment its agent is heard through the tunnel.
		if !e.VPS.IsWireGuard() {
			e.VPS.Transport = shared.TransportWireGuard
			first = true
		}
		if ap, err := netip.ParseAddrPort(e.VPS.WGEndpoint); err == nil {
			e.VPS.Host = ap.Addr().String()
		}
	})
	if entry == nil {
		return nil, shared.RegisterResponse{}, fmt.Errorf("no matching VPS — add this server in Beacle first")
	}
	if first {
		s.logAction(entry.VPS, "vps_register", "Agent connected via WireGuard", true)
	}
	return entry, ackFor(entry), nil
}

func ackFor(entry *VPSEntry) shared.RegisterResponse {
	return shared.RegisterResponse{
		OK:    "registered",
		VPSID: entry.VPS.ID,
		// Always return token so a reinstalled agent can persist credentials again.
		Token: entry.AgentToken,
	}
}

// applyAgentOnline marks an entry live from a register frame. host/tsName
// are the Tailscale identity; blank leaves the stored one alone.
func applyAgentOnline(e *VPSEntry, req shared.RegisterRequest, host, tsName string) {
	e.VPS.Status = shared.VPSOnline
	e.Restart = nil // a registering agent is back; any reboot is over
	e.VPS.LastSeen = time.Now().UTC()
	e.VPS.AgentVer = req.AgentVersion
	// Blank on an agent too old to send one; leaving the stored value
	// alone would be worse, since a stale digest reads as a definite
	// answer about bytes that are no longer running.
	e.VPS.AgentDigest = req.AgentDigest
	if req.Arch != "" {
		e.VPS.Arch = req.Arch
	}
	if req.AgentPort > 0 {
		e.VPS.AgentPort = req.AgentPort
	}
	if tsName != "" {
		e.VPS.TailscaleName = tsName
	}
	if host != "" {
		e.VPS.Host = host
	}
	applyPublicIPGeo(e, req.PublicIP)
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
