//go:build linux

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"beacle/shared"
)

// A real shell on a real PTY: what the panel types runs, the output comes
// back, and "exit" ends the session with the shell's status.
func TestRealShellRunsCommandsAndExits(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := make(chan []byte, 64)
	m := NewTerminalManager(ctx, out, false)
	defer m.CloseAll()

	send := func(s string) {
		m.Handle(shared.TerminalFrame{Session: "t", Op: shared.TermData, Data: base64.StdEncoding.EncodeToString([]byte(s))})
	}
	m.Handle(shared.TerminalFrame{Session: "t", Op: shared.TermOpen, Cols: 100, Rows: 30})
	send("echo beacle-$((40+2)); stty size\r")
	send("exit 3\r")

	var screen strings.Builder
	deadline := time.After(10 * time.Second)
	for {
		select {
		case b := <-out:
			var msg shared.AgentWSMessage
			_ = json.Unmarshal(b, &msg)
			f := msg.Terminal
			switch f.Op {
			case shared.TermData:
				d, _ := base64.StdEncoding.DecodeString(f.Data)
				screen.Write(d)
			case shared.TermError:
				t.Fatalf("terminal error: %s", f.Error)
			case shared.TermExit:
				s := screen.String()
				if !strings.Contains(s, "beacle-42") {
					t.Errorf("command output missing:\n%s", s)
				}
				if !strings.Contains(s, "30 100") {
					t.Errorf("PTY size not applied (want 30 100):\n%s", s)
				}
				if f.Code != 3 {
					t.Errorf("exit code = %d, want 3", f.Code)
				}
				return
			}
		case <-deadline:
			t.Fatalf("shell never exited; screen so far:\n%s", screen.String())
		}
	}
}

// systemd hands root SHELL=/bin/sh; the terminal must use passwd's shell.
func TestPasswdShellIn(t *testing.T) {
	passwd := "root:x:0:0:root:/root:/bin/bash\n" +
		"daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" +
		"deploy:x:1000:1000::/home/deploy:/usr/bin/zsh\n"
	for uid, want := range map[int]string{0: "/bin/bash", 1: "", 1000: "/usr/bin/zsh", 42: ""} {
		if got := passwdShellIn(passwd, uid); got != want {
			t.Errorf("uid %d: got %q, want %q", uid, got, want)
		}
	}
}
