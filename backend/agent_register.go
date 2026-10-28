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
			// A WireGuard agent that came here is on its Tailscale fallback
			// (the tunnel is down). Its token is the proof; the transport and
			// the address the panel knows it by stay as they are.
			updated := s.store.UpdateVPS(tokenEntry.VPS.ID, func(e *VPSEntry) { applyAgentOnline(e, req, "", "") })
			return updated, ackFor(updated), nil
		}
		updated := s.store.UpdateVPS(tokenEntry.VPS.ID, applyOnline)
		return updated, ackFor(updated), nil
	}

	// A VPS ID is no credential: anyone on the tailnet can read it from
	// /beacle/alive. A known server is only opened by its token, or reclaimed
	// below from its own address.
	known := req.VPSID != "" && s.store.GetVPS(req.VPSID) != nil
	if entry := s.store.GetVPS(req.VPSID); known && entry.VPS.IsWireGuard() {
		return nil, shared.RegisterResponse{}, fmt.Errorf("this server is connected over WireGuard")
	}

	// Nor is what an agent says about itself: a server added in the panel and
	// still waiting for its agent is matched by the address the socket comes
	// from, or the name Tailscale gives that address. Only a process on this
	// computer is taken at its word — it could drive the panel API anyway.
	var pending *VPSEntry
	if net.ParseIP(remoteIP).IsLoopback() {
		pending = s.store.FindPendingByTailscale(tsName, host)
	} else {
		pending = s.store.FindPendingByTailscale(tailnetName(remoteIP), remoteIP)
	}
	reclaim := false
	if pending == nil {
		// Reclaim a server whose agent lost its token (reinstall, wiped
		// config): only from the address that server connects from, never by
		// the name or IP an agent reports about itself, and not while its
		// agent is connected. It gets a new token, not the old one.
		if e := s.store.FindByTailscale("", remoteIP); e != nil && !s.agentHub.Connected(e.VPS.ID) {
			pending, reclaim = e, true
		}
	}
	if pending == nil && !known {
		// The agent already holds credentials from an earlier registration but
		// the registry no longer knows them (state.json reset / restored from a
		// backup / panel reinstalled). One on this computer is adopted back
		// under its own ID and token; any other waits for the person at the
		// panel to let it in (see rejoin.go).
		if rawToken != "" || req.VPSID != "" {
			if net.ParseIP(remoteIP).IsLoopback() {
				entry := s.store.AdoptVPS(req.VPSID, rawToken, req.Hostname, host, tsName, req.AgentVersion)
				entry = s.store.UpdateVPS(entry.VPS.ID, applyOnline)
				log.Printf("adopted agent %s (%s) — was missing from registry", entry.VPS.Name, entry.VPS.ID)
				s.logAction(entry.VPS, "vps_adopt", "Agent re-adopted with existing credentials", true)
				return entry, ackFor(entry), nil
			}
			if s.rejoins.knock(rejoinRequest{
				IP: remoteIP, TailnetName: tailnetName(remoteIP), VPSID: req.VPSID,
				Hostname: req.Hostname, AgentVersion: req.AgentVersion,
			}, rawToken) {
				log.Printf("agent at %s (%q) asks to rejoin — waiting for approval in the panel", remoteIP, req.Hostname)
				s.broadcastRejoin()
			}
			return nil, shared.RegisterResponse{}, fmt.Errorf("this server is not in Beacle's list any more — let it back in from the panel")
		}
		return nil, shared.RegisterResponse{}, fmt.Errorf("no matching VPS — add this server in Beacle first")
	}
	if pending == nil {
		return nil, shared.RegisterResponse{}, fmt.Errorf("unknown agent token for this server")
	}
	entry := s.store.UpdateVPS(pending.VPS.ID, func(e *VPSEntry) {
		if e.AgentToken == "" || reclaim {
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
	// Blank from agents too old to send one; keep the stored value then.
	if req.LanIP != "" {
		e.VPS.LanIP = req.LanIP
	}
	applyPublicIPGeo(e, req.PublicIP)
}

func agentRemoteIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	// Only `tailscale serve` on the loopback listener speaks for the real
	// client; from anyone else the header is whatever they chose to send.
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" && net.ParseIP(host).IsLoopback() {
		return xff
	}
	return host
}
