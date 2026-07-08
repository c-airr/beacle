package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

type Server struct {
	store    *Store
	hub      *Hub
	agentHub *AgentHub
	alerts   *AlertEngine
	baseURL  string // public URL of this backend, used in install commands
	dataDir  string

	uiPowerMu   sync.RWMutex
	uiPowerMode shared.PowerMode
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, shared.APIError{Error: msg})
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	return ""
}

// ---------------------------------------------------------------------------
// Agent-facing endpoints
// ---------------------------------------------------------------------------

func (s *Server) authAgent(w http.ResponseWriter, r *http.Request) *VPSEntry {
	tok := bearer(r)
	if tok == "" {
		writeErr(w, http.StatusUnauthorized, "missing token")
		return nil
	}
	e := s.store.FindByToken(tok)
	if e == nil {
		writeErr(w, http.StatusUnauthorized, "invalid token")
		return nil
	}
	return e
}

// handleAgentRegister implements zero-config auto-registration. A brand new
// agent registers without credentials and receives its VPS ID + token; the
// backend creates the VPS entry on the spot. Returning agents authenticate
// with their existing token.
func (s *Server) handleAgentWS(w http.ResponseWriter, r *http.Request) {
	s.agentHub.ServeAgentWS(w, r, s)
}

// ---------------------------------------------------------------------------
// UI-facing endpoints
// ---------------------------------------------------------------------------

func (s *Server) handleListVPS(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.store.ListVPS())
}

func (s *Server) handleVPSByID(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	entry := s.store.GetVPS(id)
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	switch r.Method {
	case http.MethodGet:
		snap := s.store.GetSnapshot(id)
		if snap == nil {
			snap = &shared.VPSSnapshot{VPS: entry.VPS}
		}
		writeJSON(w, http.StatusOK, snap)
	case http.MethodDelete:
		s.store.DeleteVPS(id)
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
		s.logAction(entry.VPS, "vps_delete", "VPS removed", true)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case http.MethodPatch:
		var req shared.UpdateVPSRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "bad json")
			return
		}
		updated := s.store.UpdateVPS(id, func(e *VPSEntry) {
			if req.Name != "" {
				e.VPS.Name = req.Name
			}
			if req.Host != "" {
				e.VPS.Host = req.Host
			}
			if req.Location != "" {
				e.VPS.Location = req.Location
			}
			if req.Latitude != 0 || req.Longitude != 0 {
				e.VPS.Latitude, e.VPS.Longitude = req.Latitude, req.Longitude
			}
			if req.Weight > 0 {
				e.VPS.Weight = req.Weight
			}
		})
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
		writeJSON(w, http.StatusOK, updated.VPS)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleCreateVPS(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	var req shared.CreateVPSRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if req.TailscaleName == "" && req.TailscaleIP == "" {
		writeErr(w, http.StatusBadRequest, "tailscale_name or tailscale_ip required")
		return
	}
	name := req.Name
	if name == "" {
		name = req.TailscaleName
	}
	entry := s.store.CreateVPS(name, req.TailscaleName, req.TailscaleIP)
	s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
	writeJSON(w, http.StatusOK, entry.VPS)
}

func (s *Server) handleInstallCommand(w http.ResponseWriter, r *http.Request) {
	base := s.backendURL()
	writeJSON(w, http.StatusOK, map[string]string{
		"install_command": vpsInstallCommand(base),
		"backend_url":     base,
		"agent_url":       agentBinaryURL,
	})
}

func (s *Server) backendURL() string {
	if ip := tailscaleSelfIPv4(); ip != "" {
		return fmt.Sprintf("http://%s:8930", ip)
	}
	return s.baseURL
}

func (s *Server) handleOverview(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"vps":       s.store.ListVPS(),
		"snapshots": s.store.ListSnapshots(),
		"alerts":    s.store.ListAlerts(),
		"actions":   s.store.ListActions(),
		"links":     s.store.ListLinks(),
	})
}

func (s *Server) handleAlerts(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.store.ListAlerts())
}

func (s *Server) handleResolveAlert(w http.ResponseWriter, r *http.Request) {
	if !s.store.ResolveAlert(r.PathValue("id")) {
		writeErr(w, http.StatusNotFound, "alert not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleActions(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.store.ListActions())
}

// --- Links ------------------------------------------------------------------

func (s *Server) handleLinks(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, s.store.ListLinks())
	case http.MethodPost:
		var req struct {
			From string `json:"from_vps_id"`
			To   string `json:"to_vps_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.From == "" || req.To == "" || req.From == req.To {
			writeErr(w, http.StatusBadRequest, "from_vps_id and to_vps_id required")
			return
		}
		if s.store.GetVPS(req.From) == nil || s.store.GetVPS(req.To) == nil {
			writeErr(w, http.StatusNotFound, "vps not found")
			return
		}
		link := s.store.CreateLink(req.From, req.To)
		go s.measureLink(link.ID)
		writeJSON(w, http.StatusOK, link)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleDeleteLink(w http.ResponseWriter, r *http.Request) {
	if !s.store.DeleteLink(r.PathValue("id")) {
		writeErr(w, http.StatusNotFound, "link not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// measureLink asks the "from" agent to ping the "to" host.
func (s *Server) measureLink(linkID string) {
	links := s.store.ListLinks()
	var link *shared.VPSLink
	for i := range links {
		if links[i].ID == linkID {
			link = &links[i]
			break
		}
	}
	if link == nil {
		return
	}
	from := s.store.GetVPS(link.FromVPSID)
	to := s.store.GetVPS(link.ToVPSID)
	if from == nil || to == nil {
		return
	}
	status, latency, loss := "down", 0.0, 100.0
	body, code, err := s.agentHub.Request(from.VPS.ID, http.MethodGet, "/api/ping?target="+url.QueryEscape(to.VPS.Host), nil, 15*time.Second)
	if err == nil && code == http.StatusOK {
		var pr shared.PingResult
		if json.Unmarshal(body, &pr) == nil && pr.Reachable {
			latency, loss = pr.LatencyMs, pr.PacketLoss
			status = "ok"
			if loss > 0 || latency > 250 {
				status = "degraded"
			}
		}
	}
	updated := s.store.UpdateLink(linkID, func(l *shared.VPSLink) {
		l.LatencyMs, l.PacketLoss, l.Status = latency, loss, status
		l.CheckedAt = time.Now().UTC()
	})
	if updated != nil {
		s.hub.Broadcast(shared.WSLinkUpdate, updated)
	}
}

// LinkMonitor refreshes all link measurements periodically.
func (s *Server) LinkMonitor() {
	for range time.Tick(30 * time.Second) {
		for _, l := range s.store.ListLinks() {
			s.measureLink(l.ID)
		}
	}
}

// ---------------------------------------------------------------------------
// Agent proxy: /api/vps/{id}/agent/* -> command over agent WebSocket tunnel
// ---------------------------------------------------------------------------

func (s *Server) handleAgentProxy(w http.ResponseWriter, r *http.Request) {
	entry := s.store.GetVPS(r.PathValue("id"))
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	rest := r.PathValue("rest")
	path := "/api/" + rest
	if r.URL.RawQuery != "" {
		path += "?" + r.URL.RawQuery
	}
	var bodyBytes []byte
	if r.Body != nil {
		bodyBytes, _ = io.ReadAll(r.Body)
	}
	respBody, code, err := s.agentHub.Request(entry.VPS.ID, r.Method, path, bodyBytes, 30*time.Second)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "agent unreachable: "+err.Error())
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead && code >= 200 && code < 300 {
		s.agentHub.RequestRefresh(entry.VPS.ID)
	}
	if r.Method != http.MethodGet {
		ok := code >= 200 && code < 300
		s.logAction(entry.VPS, r.Method+" "+path, string(truncate(respBody, 200)), ok)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(respBody)
}

func truncate(b []byte, n int) []byte {
	if len(b) > n {
		return b[:n]
	}
	return b
}

func (s *Server) logAction(v shared.VPS, action, detail string, ok bool) {
	a := s.store.AddAction(shared.ActionLog{VPSID: v.ID, VPSName: v.Name, Action: action, Detail: detail, OK: ok})
	s.hub.Broadcast(shared.WSActionLog, a)
}

// ---------------------------------------------------------------------------
// Installer + agent binary distribution
// ---------------------------------------------------------------------------

func (s *Server) handleInstallScript(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/x-shellscript")
	_, _ = w.Write([]byte(installScript(s.backendURL())))
}

func (s *Server) handleShutdown(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	go func() {
		s.store.Persist()
		time.Sleep(100 * time.Millisecond)
		os.Exit(0)
	}()
}

func (s *Server) handleDownloadAgent(w http.ResponseWriter, r *http.Request) {
	arch := r.URL.Query().Get("arch")
	if arch == "" {
		arch = "amd64"
	}
	candidates := []string{
		filepath.Join(s.dataDir, "bin", "beacle-agent-linux-"+arch),
		filepath.Join("dist", "agent", "linux-"+arch, "beacle-agent"),
		filepath.Join("dist", "agent", "beacle-agent-linux-"+arch),
	}
	var path string
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			path = c
			break
		}
	}
	if path == "" {
		writeErr(w, http.StatusNotFound,
			fmt.Sprintf("agent binary missing for linux/%s — run scripts/build.ps1", arch))
		return
	}
	f, err := os.Open(path)
	if err != nil {
		writeErr(w, http.StatusNotFound, "agent binary not available on backend (build agent for linux/"+arch+" into "+path+")")
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Beacle-Agent-Version", agentVersion(s.dataDir))
	_, _ = io.Copy(w, f)
}

func (s *Server) handleAgentVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": agentVersion(s.dataDir)})
}

func agentVersion(dataDir string) string {
	b, err := os.ReadFile(filepath.Join(dataDir, "bin", "VERSION"))
	if err != nil {
		return "0.0.0"
	}
	return strings.TrimSpace(string(b))
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	// agent
	mux.HandleFunc("GET /agent/ws", s.handleAgentWS)

	mux.HandleFunc("POST /api/vps", s.handleCreateVPS)
	mux.HandleFunc("GET /api/tailscale/devices", s.handleTailscaleDevices)
	mux.HandleFunc("POST /api/shutdown", s.handleShutdown)

	// ui
	mux.HandleFunc("GET /api/vps", s.handleListVPS)
	mux.HandleFunc("/api/vps/{id}", s.handleVPSByID)
	mux.HandleFunc("GET /api/install-command", s.handleInstallCommand)
	mux.HandleFunc("/api/vps/{id}/agent/{rest...}", s.handleAgentProxy)
	mux.HandleFunc("POST /api/ui/power-mode", s.handleUIPowerMode)
	mux.HandleFunc("GET /api/overview", s.handleOverview)
	mux.HandleFunc("GET /api/alerts", s.handleAlerts)
	mux.HandleFunc("POST /api/alerts/{id}/resolve", s.handleResolveAlert)
	mux.HandleFunc("GET /api/actions", s.handleActions)
	mux.HandleFunc("/api/links", s.handleLinks)
	mux.HandleFunc("DELETE /api/links/{id}", s.handleDeleteLink)
	mux.HandleFunc("GET /ws", s.hub.ServeWS)

	// distribution
	mux.HandleFunc("GET /install", s.handleInstallScript)
	mux.HandleFunc("GET /download/agent", s.handleDownloadAgent)
	mux.HandleFunc("GET /download/agent/version", s.handleAgentVersion)

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "beacle-backend"})
	})
	return mux
}
