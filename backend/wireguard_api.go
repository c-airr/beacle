package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/netip"
	"time"

	"beacle/shared"
)

func (s *Server) handleConnectivityProbe(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Host string `json:"host"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	p, err := probeServer(req.Host)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// wireGuardEndpoint validates what the user typed as the server's address
// and turns it into the ip:port the panel handshakes with.
func wireGuardEndpoint(host string, port int) (string, error) {
	ip, err := resolveServerIP(host)
	if err != nil {
		return "", err
	}
	if ip.IsUnspecified() || ip.IsMulticast() {
		return "", fmt.Errorf("%s is not a server address", ip)
	}
	switch shared.ClassifyIP(ip.String()) {
	case shared.IPCGNAT:
		return "", fmt.Errorf("%s is a CG-NAT address — nothing can connect to it from outside; use Tailscale", ip)
	case shared.IPLoopback, shared.IPInvalid:
		return "", fmt.Errorf("%s is not a server address", ip)
	}
	if own := panelPublicIP(); own.IsValid() && own == ip {
		return "", fmt.Errorf("%s is this computer's own internet address — the server is behind the same router, and the tunnel cannot reach it; keep it on Tailscale", ip)
	}
	if port == 0 {
		port = shared.WGDefaultPort
	}
	if port < 1 || port > 65535 {
		return "", fmt.Errorf("port %d is out of range", port)
	}
	return netip.AddrPortFrom(ip, uint16(port)).String(), nil
}

func (s *Server) createWireGuardVPS(w http.ResponseWriter, req shared.CreateVPSRequest) {
	endpoint, err := wireGuardEndpoint(req.PublicIP, req.WGPort)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	name := req.Name
	if name == "" {
		name = req.PublicIP
	}
	for _, e := range s.store.ListEntries() {
		if e.VPS.WGEndpoint != endpoint {
			continue
		}
		if e.VPS.Status != shared.VPSPending {
			writeErr(w, http.StatusConflict, fmt.Sprintf("%s is already added as %q", endpoint, e.VPS.Name))
			return
		}
		// Adding the same pending server again (back button, second try)
		// reuses its slot instead of piling up dead entries.
		entry := s.store.UpdateVPSNow(e.VPS.ID, func(x *VPSEntry) { x.VPS.Name = name })
		if entry.WGAgentKey == "" {
			if entry, err = s.wg.Rekey(entry.VPS.ID, ""); err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
		}
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
		writeJSON(w, http.StatusOK, entry.VPS)
		return
	}
	entry, err := s.wg.CreateServer(name, endpoint)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
	s.logAction(entry.VPS, "vps_create", "Server added (WireGuard)", true)
	writeJSON(w, http.StatusOK, entry.VPS)
}

func wireGuardInstallCommand(join shared.WGJoin) string {
	return fmt.Sprintf("curl -fsSL %s | sudo bash -s -- --wg %s", shared.AgentGitHubInstallURL(), join.Encode())
}

// handleWireGuardInstall returns the install command while the server's key
// is still unused. After the first handshake the key is gone from the panel
// and only regenerate can produce a new command.
func (s *Server) handleWireGuardInstall(w http.ResponseWriter, r *http.Request) {
	entry := s.store.GetVPS(r.PathValue("id"))
	if entry == nil || !entry.HasWireGuardPeer() {
		writeErr(w, http.StatusNotFound, "no WireGuard key for this server")
		return
	}
	s.writeWireGuardInstall(w, entry)
}

func (s *Server) handleWireGuardRegenerate(w http.ResponseWriter, r *http.Request) {
	entry := s.store.GetVPS(r.PathValue("id"))
	if entry == nil || !entry.HasWireGuardPeer() {
		writeErr(w, http.StatusNotFound, "no WireGuard key for this server")
		return
	}
	entry, err := s.wg.Rekey(entry.VPS.ID, "")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.logAction(entry.VPS, "wg_rekey", "WireGuard key regenerated", true)
	s.writeWireGuardInstall(w, entry)
}

func (s *Server) writeWireGuardInstall(w http.ResponseWriter, entry *VPSEntry) {
	join, err := s.wg.JoinFor(entry)
	if err != nil {
		writeErr(w, http.StatusGone, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"install_command": wireGuardInstallCommand(join),
		"join":            join.Encode(),
		"endpoint":        entry.VPS.WGEndpoint,
		"agent_tag":       githubAgentRelease("amd64").tag,
	})
}

func (s *Server) handleWireGuardStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.wg.Status())
}

func (s *Server) handleWireGuardMigrate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	id := r.PathValue("id")
	entry := s.store.GetVPS(id)
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	if entry.VPS.IsWireGuard() {
		writeErr(w, http.StatusBadRequest, "server already uses WireGuard")
		return
	}
	var req struct {
		PublicIP string `json:"public_ip"`
		WGPort   int    `json:"wg_port"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if req.PublicIP == "" {
		req.PublicIP = entry.VPS.PublicIP
	}
	if req.PublicIP == "" {
		writeErr(w, http.StatusBadRequest, "public_ip required")
		return
	}
	endpoint, err := wireGuardEndpoint(req.PublicIP, req.WGPort)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	entry, err = s.wg.Rekey(id, endpoint)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	join, err := s.wg.JoinFor(entry)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	token := join.Encode()
	body, _ := json.Marshal(shared.TransportSwitchRequest{
		Transport: shared.TransportWireGuard,
		Join:      token,
	})
	pushed := false
	if _, code, err := s.agentHub.Request(id, http.MethodPost, "/api/transport/wireguard", body, 15*time.Second); err == nil && code >= 200 && code < 300 {
		pushed = true
	}
	s.logAction(entry.VPS, "wg_migrate", "WireGuard migration started", true)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"pushed":          pushed,
		"install_command": wireGuardInstallCommand(join),
		"endpoint":        endpoint,
		"vps":             entry.VPS,
	})
}

func (s *Server) handleWireGuardSwitchTailscale(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	id := r.PathValue("id")
	entry := s.store.GetVPS(id)
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	if !entry.HasWireGuardPeer() && !entry.VPS.IsWireGuard() {
		writeErr(w, http.StatusBadRequest, "server is not on WireGuard")
		return
	}
	panelURL := s.backendURL()
	body, _ := json.Marshal(shared.TransportSwitchRequest{
		Transport:  shared.TransportTailscale,
		BackendURL: panelURL,
	})
	// An agent stranded on a dead tunnel cannot be reached to be told — and
	// while the registry still says WireGuard, it is refused over Tailscale
	// too. So when it is offline, forget the tunnel here anyway: the agent
	// reverts on its own when its trial window closes, or on a reinstall.
	if s.agentHub.Connected(id) {
		if _, code, err := s.agentHub.Request(id, http.MethodPost, "/api/transport/tailscale", body, 15*time.Second); err != nil {
			writeErr(w, http.StatusBadGateway, "agent unreachable: "+err.Error())
			return
		} else if code < 200 || code >= 300 {
			writeErr(w, code, "agent refused switch")
			return
		}
	}
	entry = s.wg.Forget(id)
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
	s.logAction(entry.VPS, "wg_switch_back", "Switched back to Tailscale", true)
	writeJSON(w, http.StatusOK, entry.VPS)
}
