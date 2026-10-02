//go:build !linux

package main

import (
	"bytes"
	"fmt"
	"io"
	"sync"
)

// devPTY stands in for a shell on the Windows dev agent: it echoes what is
// typed and answers each line, enough to work on the terminal UI.
type devPTY struct {
	r      *io.PipeReader
	w      *io.PipeWriter
	mu     sync.Mutex
	line   bytes.Buffer
	cols   int
	rows   int
	out    chan []byte // ordered output, drained into w
	exited chan struct{}
	once   sync.Once
}

func startPTY(cols, rows int) (ptyProcess, error) {
	r, w := io.Pipe()
	p := &devPTY{r: r, w: w, cols: cols, rows: rows, out: make(chan []byte, 256), exited: make(chan struct{})}
	go func() {
		for {
			select {
			case b := <-p.out:
				if _, err := w.Write(b); err != nil {
					return
				}
			case <-p.exited:
				return
			}
		}
	}()
	p.emit(fmt.Sprintf("beacle dev shell (%dx%d) - type exit to close\r\n$ ", cols, rows))
	return p, nil
}

func (p *devPTY) emit(s string) {
	select {
	case p.out <- []byte(s):
	case <-p.exited:
	}
}

func (p *devPTY) Read(b []byte) (int, error) { return p.r.Read(b) }

func (p *devPTY) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range b {
		switch c {
		case '\r', '\n':
			cmd := p.line.String()
			p.line.Reset()
			if cmd == "exit" {
				go p.Hangup()
				return len(b), nil
			}
			p.emit(fmt.Sprintf("\r\nyou typed %q (terminal %dx%d)\r\n$ ", cmd, p.cols, p.rows))
		case 0x7f, 0x08:
			if p.line.Len() > 0 {
				p.line.Truncate(p.line.Len() - 1)
				p.emit("\b \b")
			}
		default:
			p.line.WriteByte(c)
			p.emit(string([]byte{c}))
		}
	}
	return len(b), nil
}

func (p *devPTY) Resize(cols, rows int) error {
	p.mu.Lock()
	p.cols, p.rows = cols, rows
	p.mu.Unlock()
	return nil
}

func (p *devPTY) Wait() int { <-p.exited; return 0 }

func (p *devPTY) Hangup() {
	p.once.Do(func() {
		close(p.exited)
		_ = p.w.Close()
	})
}

func (p *devPTY) Close() error { p.Hangup(); return nil }
