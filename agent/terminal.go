package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"beacle/shared"
)

// Interactive shells for the panel's terminal tab. A session is a PTY on
// this machine whose bytes ride the agent WebSocket as terminal frames.
// Sessions belong to one WebSocket session: when the panel connection drops,
// every shell is hung up, so nothing keeps running with nobody watching it.

const (
	termMaxSessions = 4
	termIdle        = 30 * time.Minute
	termReadBuf     = 32 << 10
	termMaxInput    = 64 << 10 // one paste
)

// ptyProcess is a shell attached to a PTY. Read returns its output; Read
// failing means the PTY is gone.
type ptyProcess interface {
	io.ReadWriteCloser
	Resize(cols, rows int) error
	// Wait blocks until the shell exits and returns its exit status.
	Wait() int
	// Hangup ends the shell and everything it started.
	Hangup()
}

type termSession struct {
	id        string
	p         ptyProcess
	in        chan []byte // keystrokes, in order
	done      chan struct{}
	lastInput atomic.Int64 // unix nanos
	closeOnce sync.Once
}

// writeInput feeds keystrokes to the shell in order. It is its own goroutine
// because a PTY write blocks when the shell stops reading, and that must not
// stall the WebSocket read loop.
func (s *termSession) writeInput() {
	for {
		select {
		case b := <-s.in:
			if _, err := s.p.Write(b); err != nil {
				return
			}
		case <-s.done:
			return
		}
	}
}

func (s *termSession) hangup() {
	s.closeOnce.Do(func() {
		close(s.done)
		s.p.Hangup()
		_ = s.p.Close()
	})
}

type TerminalManager struct {
	ctx      context.Context
	out      chan<- []byte
	start    func(cols, rows int) (ptyProcess, error)
	disabled bool
	idle     time.Duration

	mu       sync.Mutex
	sessions map[string]*termSession
}

func NewTerminalManager(ctx context.Context, out chan<- []byte, disabled bool) *TerminalManager {
	return &TerminalManager{
		ctx:      ctx,
		out:      out,
		start:    startPTY,
		disabled: disabled,
		idle:     termIdle,
		sessions: map[string]*termSession{},
	}
}

// send queues a frame for the panel. It blocks while the socket is backed
// up, which is the backpressure a runaway `cat` needs: the shell stalls on a
// full PTY instead of the agent buffering megabytes.
func (m *TerminalManager) send(f shared.TerminalFrame) bool {
	b, err := json.Marshal(shared.AgentWSMessage{Type: shared.AgentWSTerminal, Terminal: &f})
	if err != nil {
		return false
	}
	select {
	case m.out <- b:
		// Leave room for snapshots and command results: they share this
		// queue and command results are dropped, not waited on, when it is
		// full.
		if len(m.out) > cap(m.out)/2 {
			time.Sleep(20 * time.Millisecond)
		}
		return true
	case <-m.ctx.Done():
		return false
	}
}

func (m *TerminalManager) fail(id, msg string) {
	m.send(shared.TerminalFrame{Session: id, Op: shared.TermError, Error: msg})
}

// Handle applies one frame from the panel. It never blocks on the shell.
func (m *TerminalManager) Handle(f shared.TerminalFrame) {
	if f.Session == "" {
		return
	}
	m.mu.Lock()
	s := m.sessions[f.Session]
	m.mu.Unlock()

	switch f.Op {
	case shared.TermOpen:
		m.open(f)
	case shared.TermData:
		if s == nil {
			return
		}
		b, err := base64.StdEncoding.DecodeString(f.Data)
		if err != nil || len(b) > termMaxInput {
			return
		}
		s.lastInput.Store(time.Now().UnixNano())
		select {
		case s.in <- b:
		default: // the shell has not read its input for 256 frames; drop
		}
	case shared.TermResize:
		if s != nil && f.Cols > 0 && f.Rows > 0 {
			_ = s.p.Resize(f.Cols, f.Rows)
		}
	case shared.TermClose:
		if s != nil {
			s.hangup()
		}
	}
}

func (m *TerminalManager) open(f shared.TerminalFrame) {
	if m.disabled {
		m.fail(f.Session, "the terminal is disabled on this server")
		return
	}
	m.mu.Lock()
	if _, dup := m.sessions[f.Session]; dup {
		m.mu.Unlock()
		return
	}
	if len(m.sessions) >= termMaxSessions {
		m.mu.Unlock()
		m.fail(f.Session, "too many open terminals on this server")
		return
	}
	cols, rows := f.Cols, f.Rows
	if cols <= 0 || rows <= 0 {
		cols, rows = 80, 24
	}
	p, err := m.start(cols, rows)
	if err != nil {
		m.mu.Unlock()
		m.fail(f.Session, err.Error())
		return
	}
	s := &termSession{id: f.Session, p: p, in: make(chan []byte, 256), done: make(chan struct{})}
	s.lastInput.Store(time.Now().UnixNano())
	m.sessions[f.Session] = s
	m.mu.Unlock()
	log.Printf("terminal %s opened by the panel", f.Session)

	go s.writeInput()
	go m.pump(s)
	go m.watchIdle(s)
}

// pump forwards output until the PTY closes, then reports the exit.
func (m *TerminalManager) pump(s *termSession) {
	buf := make([]byte, termReadBuf)
	for {
		n, err := s.p.Read(buf)
		if n > 0 {
			if !m.send(shared.TerminalFrame{Session: s.id, Op: shared.TermData,
				Data: base64.StdEncoding.EncodeToString(buf[:n])}) {
				s.hangup()
			}
		}
		if err != nil {
			break
		}
	}
	s.hangup()
	code := s.p.Wait()
	m.mu.Lock()
	delete(m.sessions, s.id)
	m.mu.Unlock()
	m.send(shared.TerminalFrame{Session: s.id, Op: shared.TermExit, Code: code})
	log.Printf("terminal %s closed (exit %d)", s.id, code)
}

func (m *TerminalManager) watchIdle(s *termSession) {
	tick := time.NewTicker(m.idle / 30)
	defer tick.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-tick.C:
			m.mu.Lock()
			alive := m.sessions[s.id] == s
			m.mu.Unlock()
			if !alive {
				return
			}
			if time.Since(time.Unix(0, s.lastInput.Load())) > m.idle {
				m.send(shared.TerminalFrame{Session: s.id, Op: shared.TermData,
					Data: base64.StdEncoding.EncodeToString([]byte("\r\n[beacle] closed after 30 minutes without input\r\n"))})
				s.hangup()
				return
			}
		}
	}
}

// CloseAll hangs up every shell; called when the panel connection ends.
func (m *TerminalManager) CloseAll() {
	m.mu.Lock()
	all := make([]*termSession, 0, len(m.sessions))
	for _, s := range m.sessions {
		all = append(all, s)
	}
	m.mu.Unlock()
	for _, s := range all {
		s.hangup()
	}
}
