package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

const (
	// A dead link (laptop asleep, Tailscale re-keying, VPS network drop) is
	// invisible at the TCP level, so it is only detected when pings stop being
	// answered. Kept slightly more patient than the agent's own timeout so the
	// side that reconnects is the one that can — the agent dials, the backend
	// only waits.
	agentWSReadTimeout  = 26 * time.Second
	agentWSWriteTimeout = 10 * time.Second
	agentWSPingInterval = 8 * time.Second
)

// AgentHub tracks outbound agent WebSocket connections and routes commands
// to agents without the backend initiating any inbound TCP connections.
type AgentHub struct {
	mu      sync.Mutex
	agents  map[string]*agentSession // vpsID -> session
	pending map[string]chan shared.AgentCommandResult

	store  *Store
	hub    *Hub
	alerts *AlertEngine
}

type agentSession struct {
	vpsID      string
	entry      *VPSEntry
	conn       *websocket.Conn
	send       chan []byte
	done       chan struct{}
	closeOnce  sync.Once
	writeMu    sync.Mutex
	registered atomic.Bool
	remoteIP   string
	token      string
	tokenEntry *VPSEntry
}

func NewAgentHub(store *Store, hub *Hub, alerts *AlertEngine) *AgentHub {
	return &AgentHub{
		agents:  make(map[string]*agentSession),
		pending: make(map[string]chan shared.AgentCommandResult),
		store:   store,
		hub:     hub,
		alerts:  alerts,
	}
}

// ServeAgentWS upgrades the connection; registration happens over the first WS frame.
func (h *AgentHub) ServeAgentWS(w http.ResponseWriter, r *http.Request, srv *Server) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("agent ws upgrade: %v", err)
		return
	}

	var tokenEntry *VPSEntry
	tok := bearer(r)
	if tok != "" {
		tokenEntry = h.store.FindByToken(tok)
	}

	sess := &agentSession{
		conn:       conn,
		send:       make(chan []byte, 64),
		done:       make(chan struct{}),
		remoteIP:   agentRemoteIP(r),
		token:      tok,
		tokenEntry: tokenEntry,
	}

	go h.writeLoop(sess)
	h.readLoop(sess, srv)
}

func (h *AgentHub) attachSession(sess *agentSession) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.agents[sess.vpsID]; ok && old != sess {
		old.shutdown()
	}
	h.agents[sess.vpsID] = sess
}

func (s *agentSession) shutdown() {
	s.closeOnce.Do(func() {
		close(s.done)
		_ = s.conn.Close()
	})
}

func (s *agentSession) writeText(data []byte) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(agentWSWriteTimeout))
	return s.conn.WriteMessage(websocket.TextMessage, data)
}

func (s *agentSession) writeControl(messageType int, data []byte) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	deadline := time.Now().Add(agentWSWriteTimeout)
	_ = s.conn.SetWriteDeadline(deadline)
	return s.conn.WriteControl(messageType, data, deadline)
}

func (h *AgentHub) writeLoop(sess *agentSession) {
	// A failed write means the socket is gone. Without tearing the session down
	// here the read side would sit on its deadline while the hub still reported
	// the agent as connected.
	defer sess.shutdown()

	ticker := time.NewTicker(agentWSPingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-sess.done:
			return
		case msg, ok := <-sess.send:
			if !ok {
				return
			}
			if err := sess.writeText(msg); err != nil {
				return
			}
		case <-ticker.C:
			if err := sess.writeControl(websocket.PingMessage, []byte("ping")); err != nil {
				return
			}
		}
	}
}

func (h *AgentHub) readLoop(sess *agentSession, srv *Server) {
	defer h.disconnect(sess)

	_ = sess.conn.SetReadDeadline(time.Now().Add(agentWSReadTimeout))
	sess.conn.SetPongHandler(func(string) error {
		return sess.conn.SetReadDeadline(time.Now().Add(agentWSReadTimeout))
	})
	sess.conn.SetPingHandler(func(appData string) error {
		if err := sess.writeControl(websocket.PongMessage, []byte(appData)); err != nil {
			return err
		}
		return sess.conn.SetReadDeadline(time.Now().Add(agentWSReadTimeout))
	})

	for {
		_, data, err := sess.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = sess.conn.SetReadDeadline(time.Now().Add(agentWSReadTimeout))

		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("agent ws bad frame: %v", err)
			continue
		}
		h.handleMessage(sess, srv, &msg)
	}
}

func (h *AgentHub) disconnect(sess *agentSession) {
	wasLive := false
	h.mu.Lock()
	if sess.vpsID != "" {
		if cur, ok := h.agents[sess.vpsID]; ok && cur == sess {
			delete(h.agents, sess.vpsID)
			wasLive = true
		}
	}
	h.mu.Unlock()
	sess.shutdown()
	if !wasLive {
		// Superseded by a newer socket from the same agent (reconnect) — the
		// live session owns the status now.
		return
	}
	// The socket is the only channel this agent has: once it is gone the panel
	// must say so immediately instead of showing a server as online for the
	// whole offline grace window with no data behind it. The offline *alert*
	// still waits out shared.OfflineAfterSec, so short reconnects stay quiet.
	h.store.UpdateVPS(sess.vpsID, func(e *VPSEntry) {
		if e.VPS.Status != shared.VPSPending {
			e.VPS.Status = shared.VPSOffline
		}
	})
	log.Printf("agent ws disconnected: %s", sess.vpsID)
	h.hub.Broadcast(shared.WSVPSList, h.store.ListVPS())
}

func (h *AgentHub) handleMessage(sess *agentSession, srv *Server, msg *shared.AgentWSMessage) {
	switch msg.Type {
	case shared.AgentWSRegister:
		if msg.Register == nil {
			return
		}
		entry, ack, err := srv.registerAgent(*msg.Register, sess.remoteIP, sess.token, sess.tokenEntry)
		if err != nil {
			log.Printf("agent register failed: %v", err)
			h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSError, Error: err.Error()})
			sess.shutdown()
			return
		}
		sess.entry = entry
		sess.vpsID = entry.VPS.ID
		sess.registered.Store(true)
		h.attachSession(sess)
		log.Printf("agent ws registered: %s (%s)", entry.VPS.Name, entry.VPS.ID)
		h.hub.Broadcast(shared.WSVPSList, h.store.ListVPS())
		ack.PowerMode = srv.agentPowerMode()
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSRegisterAck, RegisterAck: &ack})
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSPowerMode, Mode: ack.PowerMode})

	case shared.AgentWSMetrics:
		if !sess.registered.Load() || sess.entry == nil || msg.Metrics == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Metrics = *msg.Metrics
		})

	case shared.AgentWSDockerSnapshot:
		if !sess.registered.Load() || sess.entry == nil || msg.Docker == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Docker = *msg.Docker
		})

	case shared.AgentWSSystemdSnapshot:
		if !sess.registered.Load() || sess.entry == nil || msg.Services == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Services = *msg.Services
		})

	case shared.AgentWSPortsSnapshot:
		if !sess.registered.Load() || sess.entry == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Ports = msg.Ports
		})

	case shared.AgentWSProxySnapshot:
		if !sess.registered.Load() || sess.entry == nil || msg.Proxy == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Proxy = *msg.Proxy
		})

	case shared.AgentWSCommandResult:
		if msg.Result == nil {
			return
		}
		h.mu.Lock()
		ch, ok := h.pending[msg.Result.RequestID]
		if ok {
			delete(h.pending, msg.Result.RequestID)
		}
		h.mu.Unlock()
		if ok {
			ch <- *msg.Result
		}

	case shared.AgentWSHeartbeat:
		// Older agents may still send JSON heartbeats — treat as liveness.
		if sess.registered.Load() && sess.entry != nil {
			h.store.UpdateVPS(sess.entry.VPS.ID, func(e *VPSEntry) {
				e.VPS.LastSeen = time.Now().UTC()
				if e.VPS.Status == shared.VPSOffline {
					e.VPS.Status = shared.VPSOnline
				}
			})
		}
	}
}

func (h *AgentHub) SetPowerMode(mode shared.PowerMode) {
	h.mu.Lock()
	sessions := make([]*agentSession, 0, len(h.agents))
	for _, sess := range h.agents {
		if sess.registered.Load() {
			sessions = append(sessions, sess)
		}
	}
	h.mu.Unlock()

	msg := shared.AgentWSMessage{Type: shared.AgentWSPowerMode, Mode: mode}
	for _, sess := range sessions {
		h.send(sess, msg)
	}
}

func (h *AgentHub) RequestRefresh(vpsID string) {
	h.mu.Lock()
	sess, ok := h.agents[vpsID]
	h.mu.Unlock()
	if ok && sess.registered.Load() {
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSRefresh})
	}
}

func (h *AgentHub) RequestRefreshAll() {
	h.mu.Lock()
	sessions := make([]*agentSession, 0, len(h.agents))
	for _, sess := range h.agents {
		if sess.registered.Load() {
			sessions = append(sessions, sess)
		}
	}
	h.mu.Unlock()
	msg := shared.AgentWSMessage{Type: shared.AgentWSRefresh}
	for _, sess := range sessions {
		h.send(sess, msg)
	}
}

func (h *AgentHub) send(sess *agentSession, msg shared.AgentWSMessage) {
	if sess == nil {
		return
	}
	select {
	case <-sess.done:
		return
	default:
	}
	b, err := json.Marshal(msg)
	if err != nil {
		return
	}
	select {
	case <-sess.done:
	case sess.send <- b:
	default:
		// The agent is not draining its socket: keeping the session around
		// would keep the panel showing it as online. Drop it and let the agent
		// reconnect on its own backoff.
		log.Printf("agent ws send buffer full for %s — dropping session", sess.vpsID)
		sess.shutdown()
	}
}

// Connected reports whether an agent has a live, registered outbound WebSocket.
func (h *AgentHub) Connected(vpsID string) bool {
	h.mu.Lock()
	sess, ok := h.agents[vpsID]
	h.mu.Unlock()
	if !ok || !sess.registered.Load() {
		return false
	}
	select {
	case <-sess.done:
		return false
	default:
		return true
	}
}

// ConnectedCount is surfaced on /api/health so the desktop app can tell a
// backend that still owns agent sockets from one that is merely listening.
func (h *AgentHub) ConnectedCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	n := 0
	for _, sess := range h.agents {
		if sess.registered.Load() {
			n++
		}
	}
	return n
}

// Request sends a command to the agent over its existing WebSocket and waits
// for the correlated result. The backend never opens a TCP connection to the agent.
func (h *AgentHub) Request(vpsID, method, path string, body []byte, timeout time.Duration) ([]byte, int, error) {
	h.mu.Lock()
	sess, ok := h.agents[vpsID]
	if !ok {
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent offline (no websocket)")
	}

	requestID := commandID()
	ch := make(chan shared.AgentCommandResult, 1)
	h.pending[requestID] = ch

	var raw json.RawMessage
	if len(body) > 0 {
		raw = json.RawMessage(body)
	}
	frame, err := json.Marshal(shared.AgentWSMessage{
		Type: shared.AgentWSCommand,
		Command: &shared.AgentCommand{
			RequestID: requestID,
			Method:    method,
			Path:      path,
			Body:      raw,
		},
	})
	if err != nil {
		delete(h.pending, requestID)
		h.mu.Unlock()
		return nil, 0, err
	}
	h.mu.Unlock()

	select {
	case <-sess.done:
		h.mu.Lock()
		delete(h.pending, requestID)
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent offline (no websocket)")
	case sess.send <- frame:
	default:
		h.mu.Lock()
		delete(h.pending, requestID)
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent send buffer full")
	}

	select {
	case res := <-ch:
		return res.Body, res.StatusCode, nil
	case <-time.After(timeout):
		h.mu.Lock()
		delete(h.pending, requestID)
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent command timeout")
	}
}

func commandID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
