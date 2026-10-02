package main

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

// Terminal bridge: the app opens GET /api/vps/{id}/terminal as a WebSocket,
// and every frame on it is relayed to and from one shell on the agent. The
// route lives on the loopback panel API only, behind rejectBrowsers — a web
// page reaching this would be a root shell on every server.

// termOutBuffer is how far the app may fall behind the shell before the
// session is cut. Blocking instead would stall the agent's whole socket.
const termOutBuffer = 1024

type termSub struct {
	id    string
	vpsID string
	sess  *agentSession // the agent socket this shell lives on
	out   chan shared.TerminalFrame
	once  sync.Once
	ended chan struct{}
}

func (t *termSub) end() { t.once.Do(func() { close(t.ended) }) }

var errAgentOffline = errors.New("agent offline (no websocket)")

// OpenTerminal starts a shell on the agent and returns the stream of its
// frames.
func (h *AgentHub) OpenTerminal(vpsID string, cols, rows int) (*termSub, error) {
	h.mu.Lock()
	sess, ok := h.agents[vpsID]
	if !ok || !sess.registered.Load() {
		h.mu.Unlock()
		return nil, errAgentOffline
	}
	t := &termSub{
		id:    commandID(),
		vpsID: vpsID,
		sess:  sess,
		out:   make(chan shared.TerminalFrame, termOutBuffer),
		ended: make(chan struct{}),
	}
	if h.terms == nil {
		h.terms = map[string]*termSub{}
	}
	h.terms[t.id] = t
	h.mu.Unlock()

	h.send(sess, shared.AgentWSMessage{Type: shared.AgentWSTerminal, Terminal: &shared.TerminalFrame{
		Session: t.id, Op: shared.TermOpen, Cols: cols, Rows: rows,
	}})
	// The shell dies with the agent socket; tell the app instead of leaving
	// it typing into nothing.
	go func() {
		select {
		case <-sess.done:
			h.deliverTerminal(t, shared.TerminalFrame{Session: t.id, Op: shared.TermError, Error: "agent disconnected"})
		case <-t.ended:
		}
	}()
	return t, nil
}

// TerminalInput forwards keystrokes or a resize from the app.
func (h *AgentHub) TerminalInput(t *termSub, f shared.TerminalFrame) {
	if f.Op != shared.TermData && f.Op != shared.TermResize {
		return
	}
	f.Session = t.id
	h.send(t.sess, shared.AgentWSMessage{Type: shared.AgentWSTerminal, Terminal: &f})
}

// CloseTerminal hangs up the shell (if the agent still has it) and forgets
// the session.
func (h *AgentHub) CloseTerminal(t *termSub) {
	h.mu.Lock()
	_, live := h.terms[t.id]
	delete(h.terms, t.id)
	h.mu.Unlock()
	t.end()
	if live {
		h.send(t.sess, shared.AgentWSMessage{Type: shared.AgentWSTerminal, Terminal: &shared.TerminalFrame{
			Session: t.id, Op: shared.TermClose,
		}})
	}
}

// handleTerminalFrame routes a frame from an agent to the app that owns the
// session. An agent can only reach sessions opened on its own socket.
func (h *AgentHub) handleTerminalFrame(sess *agentSession, f *shared.TerminalFrame) {
	if f == nil {
		return
	}
	h.mu.Lock()
	t, ok := h.terms[f.Session]
	h.mu.Unlock()
	if !ok || t.sess != sess {
		return
	}
	h.deliverTerminal(t, *f)
}

func (h *AgentHub) deliverTerminal(t *termSub, f shared.TerminalFrame) {
	final := f.Op == shared.TermExit || f.Op == shared.TermError
	select {
	case <-t.ended:
		return
	case t.out <- f:
	default:
		final = true
		select {
		case t.out <- shared.TerminalFrame{Session: t.id, Op: shared.TermError, Error: "terminal output fell behind"}:
		default:
		}
	}
	if final {
		h.mu.Lock()
		delete(h.terms, t.id)
		h.mu.Unlock()
		// ended is closed by the app side once it has drained out.
	}
}

func queryInt(r *http.Request, key string, def int) int {
	if v, err := strconv.Atoi(r.URL.Query().Get(key)); err == nil && v > 0 && v < 1000 {
		return v
	}
	return def
}

// handleTerminalWS serves GET /api/vps/{id}/terminal?cols=&rows=.
func (s *Server) handleTerminalWS(w http.ResponseWriter, r *http.Request) {
	entry := s.store.GetVPS(r.PathValue("id"))
	if entry == nil {
		writeErr(w, http.StatusNotFound, "vps not found")
		return
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()

	writeFrame := func(f shared.TerminalFrame) error {
		_ = conn.SetWriteDeadline(time.Now().Add(uiWSWriteTimeout))
		return conn.WriteJSON(f)
	}

	t, err := s.agentHub.OpenTerminal(entry.VPS.ID, queryInt(r, "cols", 80), queryInt(r, "rows", 24))
	if err != nil {
		_ = writeFrame(shared.TerminalFrame{Op: shared.TermError, Error: err.Error()})
		return
	}
	defer s.agentHub.CloseTerminal(t)
	s.logAction(entry.VPS, "terminal opened", "", true)
	log.Printf("terminal %s opened on %s", t.id, entry.VPS.Name)

	// App → agent.
	readDone := make(chan struct{})
	go func() {
		defer close(readDone)
		for {
			var f shared.TerminalFrame
			if err := conn.ReadJSON(&f); err != nil {
				return
			}
			if f.Op == shared.TermClose {
				return
			}
			s.agentHub.TerminalInput(t, f)
		}
	}()

	// Agent → app, until the shell ends or the app goes away.
	for {
		select {
		case f := <-t.out:
			if writeFrame(f) != nil {
				return
			}
			if f.Op == shared.TermExit || f.Op == shared.TermError {
				_ = conn.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""), time.Now().Add(time.Second))
				return
			}
		case <-readDone:
			return
		}
	}
}
