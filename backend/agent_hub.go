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
	vpsID string
	conn  *websocket.Conn
	send  chan []byte
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

func (h *AgentHub) ServeAgent(w http.ResponseWriter, r *http.Request, entry *VPSEntry) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("agent ws upgrade: %v", err)
		return
	}

	sess := &agentSession{
		vpsID: entry.VPS.ID,
		conn:  conn,
		send:  make(chan []byte, 32),
	}

	h.mu.Lock()
	if old, ok := h.agents[entry.VPS.ID]; ok {
		close(old.send)
		_ = old.conn.Close()
	}
	h.agents[entry.VPS.ID] = sess
	h.mu.Unlock()

	updated := h.store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.Status = shared.VPSOnline
		e.VPS.LastSeen = time.Now().UTC()
	})
	if updated != nil {
		h.hub.Broadcast(shared.WSVPSList, h.store.ListVPS())
	}
	log.Printf("agent ws connected: %s (%s)", updated.VPS.Name, entry.VPS.ID)

	go h.writeLoop(sess)
	h.readLoop(sess, entry)
}

func (h *AgentHub) writeLoop(sess *agentSession) {
	for msg := range sess.send {
		if err := sess.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			return
		}
	}
}

func (h *AgentHub) readLoop(sess *agentSession, entry *VPSEntry) {
	defer h.disconnect(sess)

	for {
		_, data, err := sess.conn.ReadMessage()
		if err != nil {
			return
		}
		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("agent ws bad frame from %s: %v", sess.vpsID, err)
			continue
		}
		h.handleMessage(sess, entry, &msg)
	}
}

func (h *AgentHub) disconnect(sess *agentSession) {
	h.mu.Lock()
	if cur, ok := h.agents[sess.vpsID]; ok && cur == sess {
		delete(h.agents, sess.vpsID)
	}
	h.mu.Unlock()
	close(sess.send)
	_ = sess.conn.Close()
	log.Printf("agent ws disconnected: %s", sess.vpsID)
}

func (h *AgentHub) handleMessage(sess *agentSession, entry *VPSEntry, msg *shared.AgentWSMessage) {
	switch msg.Type {
	case shared.AgentWSReport:
		if msg.Report != nil {
			applyAgentReport(h.store, h.hub, h.alerts, entry, *msg.Report)
		}
	case shared.AgentWSCommandResult:
		if msg.Result == nil {
			return
		}
		h.mu.Lock()
		ch, ok := h.pending[msg.Result.ID]
		if ok {
			delete(h.pending, msg.Result.ID)
		}
		h.mu.Unlock()
		if ok {
			ch <- *msg.Result
		}
	case shared.AgentWSPing:
		h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSPong})
	case shared.AgentWSPong:
		// keepalive response, ignore
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

	id := commandID()
	ch := make(chan shared.AgentCommandResult, 1)
	h.pending[id] = ch

	var raw json.RawMessage
	if len(body) > 0 {
		raw = json.RawMessage(body)
	}
	frame, err := json.Marshal(shared.AgentWSMessage{
		Type: shared.AgentWSCommand,
		Command: &shared.AgentCommand{
			ID:     id,
			Method: method,
			Path:   path,
			Body:   raw,
		},
	})
	if err != nil {
		delete(h.pending, id)
		h.mu.Unlock()
		return nil, 0, err
	}
	h.mu.Unlock()

	select {
	case sess.send <- frame:
	default:
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent send buffer full")
	}

	select {
	case res := <-ch:
		return res.Body, res.StatusCode, nil
	case <-time.After(timeout):
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
		return nil, 0, fmt.Errorf("agent command timeout")
	}
}

func commandID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// applyAgentReport updates registry state from an agent report (HTTP or WS).
func applyAgentReport(store *Store, hub *Hub, alerts *AlertEngine, entry *VPSEntry, rep shared.AgentReport) {
	updated := store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.LastSeen = time.Now().UTC()
		e.VPS.Status = statusFor(rep.Metrics)
		e.VPS.AgentVer = rep.Version
	})
	snap := &shared.VPSSnapshot{
		VPS:      updated.VPS,
		Metrics:  rep.Metrics,
		Docker:   rep.Docker,
		Services: rep.Services,
		Proxy:    rep.Proxy,
		Updated:  time.Now().UTC(),
	}
	store.SetSnapshot(snap)
	alerts.Evaluate(updated.VPS, &rep)
	hub.Broadcast(shared.WSVPSUpdate, snap)
}
