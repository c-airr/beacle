package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"beacle/shared"
)

// fakePTY records what was typed and lets the test write "output".
type fakePTY struct {
	outR *io.PipeReader
	outW *io.PipeWriter

	mu      sync.Mutex
	typed   strings.Builder
	cols    int
	rows    int
	exited  chan struct{}
	once    sync.Once
	hungUp  bool
	exitErr int
}

func newFakePTY(cols, rows int) *fakePTY {
	r, w := io.Pipe()
	return &fakePTY{outR: r, outW: w, cols: cols, rows: rows, exited: make(chan struct{})}
}

func (p *fakePTY) Read(b []byte) (int, error) { return p.outR.Read(b) }
func (p *fakePTY) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.typed.Write(b)
	return len(b), nil
}
func (p *fakePTY) Resize(c, r int) error {
	p.mu.Lock()
	p.cols, p.rows = c, r
	p.mu.Unlock()
	return nil
}
func (p *fakePTY) Wait() int { <-p.exited; return p.exitErr }
func (p *fakePTY) Hangup() {
	p.once.Do(func() {
		p.mu.Lock()
		p.hungUp = true
		p.mu.Unlock()
		_ = p.outW.Close()
		close(p.exited)
	})
}
func (p *fakePTY) Close() error { return nil }

type termHarness struct {
	t    *testing.T
	m    *TerminalManager
	out  chan []byte
	ptys []*fakePTY
	mu   sync.Mutex
}

func newTermHarness(t *testing.T, disabled bool) *termHarness {
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	h := &termHarness{t: t, out: make(chan []byte, 64)}
	h.m = NewTerminalManager(ctx, h.out, disabled)
	h.m.start = func(cols, rows int) (ptyProcess, error) {
		p := newFakePTY(cols, rows)
		h.mu.Lock()
		h.ptys = append(h.ptys, p)
		h.mu.Unlock()
		return p, nil
	}
	return h
}

func (h *termHarness) pty(i int) *fakePTY {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.ptys[i]
}

// next waits for the next frame the agent sends to the panel.
func (h *termHarness) next() shared.TerminalFrame {
	h.t.Helper()
	select {
	case b := <-h.out:
		var msg shared.AgentWSMessage
		if err := json.Unmarshal(b, &msg); err != nil || msg.Type != shared.AgentWSTerminal || msg.Terminal == nil {
			h.t.Fatalf("not a terminal frame: %s", b)
		}
		return *msg.Terminal
	case <-time.After(2 * time.Second):
		h.t.Fatal("no frame from the agent")
	}
	return shared.TerminalFrame{}
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func eventually(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition never became true")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestTerminalCarriesKeystrokesInOrderAndOutputBack(t *testing.T) {
	h := newTermHarness(t, false)
	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermOpen, Cols: 120, Rows: 40})
	eventually(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.ptys) == 1 })
	p := h.pty(0)
	if p.cols != 120 || p.rows != 40 {
		t.Fatalf("opened at %dx%d, want 120x40", p.cols, p.rows)
	}

	for _, k := range []string{"l", "s", " ", "-", "l", "a", "\r"} {
		h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermData, Data: b64(k)})
	}
	eventually(t, func() bool { p.mu.Lock(); defer p.mu.Unlock(); return p.typed.String() == "ls -la\r" })

	go func() { _, _ = p.outW.Write([]byte("total 0\r\n")) }()
	f := h.next()
	got, _ := base64.StdEncoding.DecodeString(f.Data)
	if f.Op != shared.TermData || f.Session != "s1" || string(got) != "total 0\r\n" {
		t.Fatalf("output frame = %+v (%q)", f, got)
	}

	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermResize, Cols: 200, Rows: 50})
	eventually(t, func() bool { p.mu.Lock(); defer p.mu.Unlock(); return p.cols == 200 && p.rows == 50 })
}

func TestClosingATerminalReportsTheExit(t *testing.T) {
	h := newTermHarness(t, false)
	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermOpen})
	eventually(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.ptys) == 1 })
	h.pty(0).exitErr = 130

	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermClose})
	f := h.next()
	if f.Op != shared.TermExit || f.Code != 130 {
		t.Fatalf("want exit 130, got %+v", f)
	}
	h.m.mu.Lock()
	n := len(h.m.sessions)
	h.m.mu.Unlock()
	if n != 0 {
		t.Fatalf("closed session still registered (%d)", n)
	}
}

func TestTerminalOptOutAnswersWithAnError(t *testing.T) {
	h := newTermHarness(t, true)
	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermOpen})
	f := h.next()
	if f.Op != shared.TermError || !strings.Contains(f.Error, "disabled") {
		t.Fatalf("want a disabled error, got %+v", f)
	}
	if len(h.ptys) != 0 {
		t.Fatal("a shell was started despite the opt-out")
	}
}

func TestTerminalSessionsAreCapped(t *testing.T) {
	h := newTermHarness(t, false)
	for i := 0; i < termMaxSessions; i++ {
		h.m.Handle(shared.TerminalFrame{Session: string(rune('a' + i)), Op: shared.TermOpen})
	}
	h.m.Handle(shared.TerminalFrame{Session: "one-too-many", Op: shared.TermOpen})
	f := h.next()
	if f.Op != shared.TermError || f.Session != "one-too-many" {
		t.Fatalf("want an error for the extra session, got %+v", f)
	}
}

func TestDroppedPanelHangsUpEveryShell(t *testing.T) {
	h := newTermHarness(t, false)
	h.m.Handle(shared.TerminalFrame{Session: "a", Op: shared.TermOpen})
	h.m.Handle(shared.TerminalFrame{Session: "b", Op: shared.TermOpen})
	eventually(t, func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.ptys) == 2 })

	h.m.CloseAll()
	for i := 0; i < 2; i++ {
		p := h.pty(i)
		eventually(t, func() bool { p.mu.Lock(); defer p.mu.Unlock(); return p.hungUp })
	}
}

func TestIdleTerminalIsClosed(t *testing.T) {
	h := newTermHarness(t, false)
	h.m.idle = 60 * time.Millisecond
	h.m.Handle(shared.TerminalFrame{Session: "s1", Op: shared.TermOpen})

	f := h.next()
	got, _ := base64.StdEncoding.DecodeString(f.Data)
	if f.Op != shared.TermData || !strings.Contains(string(got), "without input") {
		t.Fatalf("want the idle notice, got %+v (%q)", f, got)
	}
	if f = h.next(); f.Op != shared.TermExit {
		t.Fatalf("want exit after idle close, got %+v", f)
	}
}
