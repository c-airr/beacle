package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
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
	registered bool
	remoteIP   string
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
	if tok := bearer(r); tok != "" {
		tokenEntry = h.store.FindByToken(tok)
	}

	sess := &agentSession{
		conn:       conn,
		send:       make(chan []byte, 64),
		remoteIP:   agentRemoteIP(r),
		tokenEntry: tokenEntry,
	}

	go h.writeLoop(sess)
	go h.heartbeatLoop(sess)
	h.readLoop(sess, srv)
}

func (h *AgentHub) attachSession(sess *agentSession) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if old, ok := h.agents[sess.vpsID]; ok && old != sess {
		close(old.send)
		_ = old.conn.Close()
	}
	h.agents[sess.vpsID] = sess
}

func (h *AgentHub) writeLoop(sess *agentSession) {
	for msg := range sess.send {
		_ = sess.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
		if err := sess.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			return
		}
	}
}

func (h *AgentHub) heartbeatLoop(sess *agentSession) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		if !sess.registered {
			continue
		}
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSHeartbeat})
	}
}

func (h *AgentHub) readLoop(sess *agentSession, srv *Server) {
	defer h.disconnect(sess)

	_ = sess.conn.SetReadDeadline(time.Now().Add(90 * time.Second))
	sess.conn.SetPongHandler(func(string) error {
		return sess.conn.SetReadDeadline(time.Now().Add(90 * time.Second))
	})

	for {
		_, data, err := sess.conn.ReadMessage()
		if err != nil {
			return
		}
		_ = sess.conn.SetReadDeadline(time.Now().Add(90 * time.Second))

		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("agent ws bad frame: %v", err)
			continue
		}
		h.handleMessage(sess, srv, &msg)
	}
}

func (h *AgentHub) disconnect(sess *agentSession) {
	h.mu.Lock()
	if sess.vpsID != "" {
		if cur, ok := h.agents[sess.vpsID]; ok && cur == sess {
			delete(h.agents, sess.vpsID)
		}
	}
	h.mu.Unlock()
	close(sess.send)
	_ = sess.conn.Close()
	if sess.vpsID != "" {
		log.Printf("agent ws disconnected: %s", sess.vpsID)
		h.hub.Broadcast(shared.WSVPSList, h.store.ListVPS())
	}
}

func (h *AgentHub) handleMessage(sess *agentSession, srv *Server, msg *shared.AgentWSMessage) {
	switch msg.Type {
	case shared.AgentWSRegister:
		if msg.Register == nil {
			return
		}
		entry, ack, err := srv.registerAgent(*msg.Register, sess.remoteIP, sess.tokenEntry)
		if err != nil {
			log.Printf("agent register failed: %v", err)
			h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSError, Error: err.Error()})
			_ = sess.conn.Close()
			return
		}
		sess.entry = entry
		sess.vpsID = entry.VPS.ID
		sess.registered = true
		h.attachSession(sess)
		log.Printf("agent ws registered: %s (%s)", entry.VPS.Name, entry.VPS.ID)
		h.hub.Broadcast(shared.WSVPSList, h.store.ListVPS())
		ack.PowerMode = srv.agentPowerMode()
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSRegisterAck, RegisterAck: &ack})
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSPowerMode, Mode: ack.PowerMode})

	case shared.AgentWSMetrics:
		if !sess.registered || sess.entry == nil || msg.Metrics == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Metrics = *msg.Metrics
		})

	case shared.AgentWSDockerSnapshot:
		if !sess.registered || sess.entry == nil || msg.Docker == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Docker = *msg.Docker
		})

	case shared.AgentWSSystemdSnapshot:
		if !sess.registered || sess.entry == nil || msg.Services == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Services = *msg.Services
		})

	case shared.AgentWSPortsSnapshot:
		if !sess.registered || sess.entry == nil {
			return
		}
		mergeSnapshot(h.store, h.hub, h.alerts, sess.entry, msg.AgentVer, func(snap *shared.VPSSnapshot) {
			snap.Ports = msg.Ports
		})

	case shared.AgentWSProxySnapshot:
		if !sess.registered || sess.entry == nil || msg.Proxy == nil {
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
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSHeartbeat})
	}
}

func (h *AgentHub) SetPowerMode(mode shared.PowerMode) {
	h.mu.Lock()
	sessions := make([]*agentSession, 0, len(h.agents))
	for _, sess := range h.agents {
		if sess.registered {
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
	if ok && sess.registered {
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSRefresh})
	}
}

func (h *AgentHub) RequestRefreshAll() {
	h.mu.Lock()
	sessions := make([]*agentSession, 0, len(h.agents))
	for _, sess := range h.agents {
		if sess.registered {
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
	b, err := json.Marshal(msg)
	if err != nil {
		return
	}
	select {
	case sess.send <- b:
	default:
		log.Printf("agent ws send buffer full for %s", sess.vpsID)
	}
}

// Connected reports whether an agent has an active outbound WebSocket.
func (h *AgentHub) Connected(vpsID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.agents[vpsID]
	return ok
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
