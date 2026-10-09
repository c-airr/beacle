//go:build linux

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
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

func TestLoginAccountsIn(t *testing.T) {
	passwd := strings.Join([]string{
		"root:x:0:0:root:/root:/bin/bash",
		"daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin",
		"opc:x:1001:1001::/home/opc:/bin/bash",
		"ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash",
		"nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin",
		"git:x:1002:1002::/home/git:/usr/bin/git-shell-but-nologin",
		"beacle-a1b2c3:x:1003:1003:Beacle temporary login:/home/beacle-a1b2c3:/bin/bash",
		"svc:x:1004:1004::/srv:/bin/false",
	}, "\n")
	var names []string
	for _, a := range loginAccountsIn(passwd, 1000) {
		names = append(names, a.name)
	}
	if got := strings.Join(names, ","); got != "root,ubuntu,opc" {
		t.Fatalf("got %s, want root,ubuntu,opc", got)
	}
}

// A shell opened as an ordinary account runs as that account, with its
// groups, in its home, on a tty it owns. Only as root in a throwaway
// container: BEACLE_ROOT_TESTS=1.
func TestShellAsAnotherAccount(t *testing.T) {
	if os.Getenv("BEACLE_ROOT_TESTS") != "1" || os.Geteuid() != 0 {
		t.Skip("needs root in a throwaway container (BEACLE_ROOT_TESTS=1)")
	}
	if out, err := exec.Command("useradd", "-m", "-s", "/bin/bash", "-G", "adm", "tester").CombinedOutput(); err != nil {
		t.Fatalf("useradd: %v %s", err, out)
	}
	defer exec.Command("userdel", "-r", "tester").Run()

	if u := terminalUsers(); u.Main != "tester" || !containsString(u.Users, "root") {
		t.Fatalf("terminalUsers %+v", u)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := make(chan []byte, 64)
	m := NewTerminalManager(ctx, out, false)
	defer m.CloseAll()
	m.Handle(shared.TerminalFrame{Session: "u", Op: shared.TermOpen, Cols: 100, Rows: 30, User: "tester"})
	in := "echo who=$(id -un) home=$PWD groups=$(id -Gn | tr ' ' ,) ttyowner=$(stat -c %U $(tty)); exit\r"
	m.Handle(shared.TerminalFrame{Session: "u", Op: shared.TermData, Data: base64.StdEncoding.EncodeToString([]byte(in))})

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
				for _, want := range []string{"who=tester", "home=/home/tester", "adm", "ttyowner=tester"} {
					if !strings.Contains(s, want) {
						t.Errorf("%q missing:\n%s", want, s)
					}
				}
				return
			}
		case <-deadline:
			t.Fatalf("shell never exited; screen so far:\n%s", screen.String())
		}
	}
}

// Asking for an account that is not a login account opens nothing.
func TestShellRefusesUnknownAccount(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root")
	}
	for _, name := range []string{"daemon", "nobody", "no-such-user"} {
		if _, err := shellAccount(name); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}


// The login message comes before the prompt, with line ends a terminal
// understands, and ~/.hushlogin silences it.
func TestLoginMessageIsTheMotdUnlessHushed(t *testing.T) {
	dir := t.TempDir()
	dyn, static := dir+"/motd.dynamic", dir+"/motd"
	_ = os.WriteFile(dyn, []byte("Welcome to Ubuntu\n\n * Docs\n"), 0o644)
	_ = os.WriteFile(static, []byte("be nice\r\n"), 0o644)
	old := motdFiles
	motdFiles = []string{dyn, dir + "/missing", static}
	defer func() { motdFiles = old }()

	home := t.TempDir()
	if got, want := string(loginMessage(home)), "Welcome to Ubuntu\r\n\r\n * Docs\r\nbe nice\r\n"; got != want {
		t.Fatalf("loginMessage = %q, want %q", got, want)
	}
	_ = os.WriteFile(home+"/.hushlogin", nil, 0o644)
	if got := loginMessage(home); got != nil {
		t.Fatalf("hushed loginMessage = %q, want nothing", got)
	}
}