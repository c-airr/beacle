package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

type Server struct {
	store     *Store
	hub       *Hub
	agentHub  *AgentHub
	alerts    *AlertEngine
	history   *History
	webhooks  *WebhookService
	wg        *WireGuardService
	baseURL   string // public URL of this backend, used in install commands
	dataDir   string
	startedAt time.Time
	uptime    *UptimeLog
	spikes    *Spikes

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
		s.wg.RemovePeer(entry.VPS.WGPublicKey)
		if s.history != nil {
			s.history.Forget(id)
			s.spikes.Forget(id)
		}
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
			if req.Tags != nil {
				e.VPS.Tags = normalizeTags(*req.Tags)
			}
			if req.Thresholds != nil {
				e.VPS.Thresholds = normalizeThresholds(req.Thresholds)
			}
		})
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
		writeJSON(w, http.StatusOK, updated.VPS)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// normalizeTags trims, de-duplicates (case-insensitively) and caps the tag
// list so a paste accident cannot grow the registry without bound.
func normalizeTags(tags []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, t := range tags {
		t = strings.TrimSpace(t)
		if t == "" || len(out) >= 20 {
			continue
		}
		if len(t) > 32 {
			t = t[:32]
		}
		if low := strings.ToLower(t); !seen[low] {
			seen[low] = true
			out = append(out, t)
		}
	}
	return out
}

// normalizeThresholds clamps overrides to 0-100. An all-zero struct collapses
// to nil ("use globals") so the panel can tell "customized" from "default"
// by presence alone.
func normalizeThresholds(t *shared.VPSThresholds) *shared.VPSThresholds {
	clamp := func(v float64) float64 {
		if v < 0 {
			return 0
		}
		if v > 100 {
			return 100
		}
		return v
	}
	t.CPUHigh, t.MemHigh, t.DiskHigh = clamp(t.CPUHigh), clamp(t.MemHigh), clamp(t.DiskHigh)
	if t.CPUHigh == 0 && t.MemHigh == 0 && t.DiskHigh == 0 {
		return nil
	}
	return t
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
	if req.Transport == shared.TransportWireGuard {
		s.createWireGuardVPS(w, req)
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
		"agent_url":       shared.AgentGitHubBinaryURL("amd64"),
		// The real release name from GitHub, not a compiled-in guess: the
		// install one-liner pulls from Latest, so this has to say which one
		// that currently is.
		"agent_tag": githubAgentRelease("amd64").tag,
	})
}

func (s *Server) backendURL() string {
	if ip := tailscaleSelfIPv4(); ip != "" {
		return fmt.Sprintf("http://%s:9930", ip)
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
// handleVPSHistory serves recorded metric samples for one server.
//
// The window is given in hours back from now, or as an explicit from/to pair in
// RFC3339 so the panel can scroll to a specific night. The response also
// carries the span actually held, which lets the UI bound its scrolling to real
// data instead of offering two empty weeks.
func (s *Server) handleVPSHistory(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if s.store.GetVPS(id) == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	if s.history == nil {
		writeJSON(w, http.StatusOK, map[string]any{"samples": []shared.MetricSample{}})
		return
	}

	var from, to time.Time
	q := r.URL.Query()
	if v := q.Get("from"); v != "" {
		from, _ = time.Parse(time.RFC3339, v)
	}
	if v := q.Get("to"); v != "" {
		to, _ = time.Parse(time.RFC3339, v)
	}
	if from.IsZero() {
		hours := 24
		if v := q.Get("hours"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 24*30 {
				hours = n
			}
		}
		from = time.Now().Add(-time.Duration(hours) * time.Hour)
	}

	samples := s.history.Query(id, from, to)
	// Spikes ride along with the chart data rather than needing a second
	// round trip: the panel wants to mark them on the line as it draws it.
	spikes := s.spikes.Query(id, from, to)
	first, last := s.history.Span(id)
	// Stretches where the panel itself was not running. Without these the
	// chart cannot tell "this server was down" from "nobody was recording",
	// and drew both as an outage.
	var panelDown []map[string]any
	if s.uptime != nil {
		for _, d := range s.uptime.DownFrom(from, to) {
			panelDown = append(panelDown, map[string]any{"from": d.From, "to": d.To})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"samples":    samples,
		"first":      first,
		"last":       last,
		"panel_down": panelDown,
		"spikes":     spikes,
	})
}

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
	// Long operations get a matching budget: image pulls and prunes take
	// minutes, and answering 502 while the agent is still working would leave
	// the panel and the VPS disagreeing about what happened.
	timeout := 30 * time.Second
	switch {
	case strings.HasPrefix(path, "/api/docker/compose/"):
		timeout = 6 * time.Minute
	case path == "/api/docker/prune":
		timeout = 3 * time.Minute
	case strings.HasSuffix(path, "/exec"):
		timeout = 45 * time.Second
	case rest == "fs/delete":
		timeout = 3 * time.Minute // recursive deletes of big trees
	case strings.HasPrefix(rest, "fs/"):
		timeout = time.Minute // 1 MiB chunks over a slow uplink
	}
	isFS := strings.HasPrefix(rest, "fs/")
	respBody, code, err := s.agentHub.Request(entry.VPS.ID, r.Method, path, bodyBytes, timeout)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "agent unreachable: "+err.Error())
		return
	}
	// A reboot/poweroff issued through the panel marks the VPS before the
	// socket drops, so the offline watcher never sees an "outage" here.
	if r.Method == http.MethodPost && code >= 200 && code < 300 &&
		(rest == "system/reboot" || rest == "system/poweroff") {
		reason := "poweroff"
		restore := false
		if rest == "system/reboot" {
			reason = "reboot"
			var req shared.RebootRequest
			_ = json.Unmarshal(bodyBytes, &req)
			restore = req.Restore
		}
		s.store.MarkRestart(entry.VPS.ID, reason, restore)
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
	}
	// File operations change nothing a snapshot shows; refreshing on every
	// upload chunk would resend docker/systemd state a hundred times a file.
	if !isFS && r.Method != http.MethodGet && r.Method != http.MethodHead && code >= 200 && code < 300 {
		s.agentHub.RequestRefresh(entry.VPS.ID)
	}
	if r.Method != http.MethodGet && !(rest == "fs/upload" && !finalUpload(bodyBytes)) {
		ok := code >= 200 && code < 300
		detail := string(truncate(respBody, 200))
		if isFS && ok {
			detail = fsTarget(bodyBytes) // which file, not the echoed entry
		}
		s.logAction(entry.VPS, r.Method+" "+path, detail, ok)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_, _ = w.Write(respBody)
}

// fsTarget names the file an fs/* request touched, for the action log.
func fsTarget(body []byte) string {
	var req struct {
		Path string `json:"path"`
		From string `json:"from"`
		To   string `json:"to"`
	}
	_ = json.Unmarshal(body, &req)
	if req.From != "" {
		return req.From + " -> " + req.To
	}
	return req.Path
}

// finalUpload reports whether an fs/upload body is the last chunk, the only
// one worth an entry in the action log.
func finalUpload(body []byte) bool {
	var req struct {
		Final bool `json:"final"`
	}
	_ = json.Unmarshal(body, &req)
	return req.Final
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

// ---------------------------------------------------------------------------
// Webhooks: destinations, election, delivery test
// ---------------------------------------------------------------------------

func (s *Server) handleGetWebhooks(w http.ResponseWriter, r *http.Request) {
	primary, secondary := s.webhooks.Elect()
	writeJSON(w, http.StatusOK, map[string]any{
		"targets":   s.webhooks.Targets(),
		"primary":   primary,
		"secondary": secondary,
	})
}

func (s *Server) handlePutWebhooks(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Targets []shared.WebhookTarget `json:"targets"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if req.Targets == nil {
		req.Targets = []shared.WebhookTarget{}
	}
	if err := s.webhooks.SetTargets(req.Targets); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleTestWebhooks(w http.ResponseWriter, r *http.Request) {
	via, err := s.webhooks.SendTest()
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	if via == "" {
		writeErr(w, http.StatusBadRequest, "no webhook targets configured")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "via": via})
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
	mux.HandleFunc("POST /api/connectivity/probe", s.handleConnectivityProbe)
	mux.HandleFunc("GET /api/vps/{id}/wireguard/install", s.handleWireGuardInstall)
	mux.HandleFunc("POST /api/vps/{id}/wireguard/regenerate", s.handleWireGuardRegenerate)
	mux.HandleFunc("GET /api/wireguard/status", s.handleWireGuardStatus)
	mux.HandleFunc("POST /api/vps/{id}/wireguard/migrate", s.handleWireGuardMigrate)
	mux.HandleFunc("POST /api/vps/{id}/wireguard/switch-tailscale", s.handleWireGuardSwitchTailscale)
	mux.HandleFunc("POST /api/shutdown", s.handleShutdown)

	// ui
	mux.HandleFunc("GET /api/vps", s.handleListVPS)
	mux.HandleFunc("/api/vps/{id}", s.handleVPSByID)
	mux.HandleFunc("GET /api/install-command", s.handleInstallCommand)
	mux.HandleFunc("GET /api/vps/{id}/history", s.handleVPSHistory)
	mux.HandleFunc("/api/vps/{id}/agent/{rest...}", s.handleAgentProxy)
	mux.HandleFunc("POST /api/ui/power-mode", s.handleUIPowerMode)
	mux.HandleFunc("GET /api/overview", s.handleOverview)
	mux.HandleFunc("GET /api/alerts", s.handleAlerts)
	mux.HandleFunc("POST /api/alerts/{id}/resolve", s.handleResolveAlert)
	mux.HandleFunc("GET /api/webhooks", s.handleGetWebhooks)
	mux.HandleFunc("PUT /api/webhooks", s.handlePutWebhooks)
	mux.HandleFunc("POST /api/webhooks/test", s.handleTestWebhooks)
	mux.HandleFunc("GET /api/actions", s.handleActions)
	mux.HandleFunc("/api/links", s.handleLinks)
	mux.HandleFunc("DELETE /api/links/{id}", s.handleDeleteLink)
	mux.HandleFunc("GET /ws", s.hub.ServeWS)

	// distribution
	mux.HandleFunc("GET /install", s.handleInstallScript)
	mux.HandleFunc("GET /download/agent", s.handleDownloadAgent)
	mux.HandleFunc("GET /download/agent/version", s.handleAgentVersion)

	mux.HandleFunc("GET /api/health", s.handleHealth)
	return mux
}

// handleHealth identifies this process so the desktop app can adopt a backend
// that is already running (and already owns the agent sockets) instead of
// killing it and forcing every agent through a reconnect.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	dataDir, err := filepath.Abs(s.dataDir)
	if err != nil {
		dataDir = s.dataDir
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"service":    "beacle-backend",
		// 2: panel API on loopback, agents on their own listeners.
		"api_level":  2,
		"pid":        os.Getpid(),
		"data_dir":   dataDir,
		"agents":     s.agentHub.ConnectedCount(),
		"uptime_sec": int(time.Since(s.startedAt).Seconds()),
	})
}
