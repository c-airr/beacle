//go:build linux

package main

import (
	"errors"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"
)

type linuxPTY struct {
	*os.File // PTY master
	cmd      *exec.Cmd
}

// loginShell picks the user's shell from /etc/passwd, then bash. Not $SHELL:
// systemd sets it to /bin/sh for root whatever passwd says, and dash in a
// terminal has no history, no arrow keys and no tab completion.
func loginShell() string {
	for _, sh := range []string{passwdShell(os.Getuid()), "/bin/bash", os.Getenv("SHELL"), "/bin/sh"} {
		if sh == "" {
			continue
		}
		if _, err := os.Stat(sh); err == nil {
			return sh
		}
	}
	return "/bin/sh"
}

// passwdShell is the login shell /etc/passwd gives uid, or "".
func passwdShell(uid int) string {
	b, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return ""
	}
	return passwdShellIn(string(b), uid)
}

func passwdShellIn(passwd string, uid int) string {
	want := strconv.Itoa(uid)
	for _, line := range strings.Split(passwd, "\n") {
		f := strings.Split(strings.TrimSpace(line), ":")
		if len(f) == 7 && f[2] == want {
			// nologin and false are for service accounts, not a person at a
			// terminal.
			if strings.HasSuffix(f[6], "nologin") || strings.HasSuffix(f[6], "/false") {
				return ""
			}
			return f[6]
		}
	}
	return ""
}

// shellUser is who the shell runs as — the agent's own user (root under the
// shipped unit) — and where it starts.
func shellUser() (name, home string) {
	name, home = "root", "/"
	if u, err := user.Current(); err == nil {
		name = u.Username
		if f, err := os.Open(u.HomeDir); err == nil {
			f.Close()
			home = u.HomeDir
		}
	}
	return name, home
}

func startPTY(cols, rows int) (ptyProcess, error) {
	shell := loginShell()
	name, home := shellUser()
	cmd := exec.Command(shell, "-l")
	cmd.Dir = home
	// A clean login environment: the agent's own GOMEMLIMIT/GOGC must not
	// leak into whatever the user runs.
	cmd.Env = []string{
		"TERM=xterm-256color",
		"COLORTERM=truecolor",
		"HOME=" + home,
		"USER=" + name,
		"LOGNAME=" + name,
		"SHELL=" + shell,
		"LANG=C.UTF-8",
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
	}
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, err
	}
	return &linuxPTY{File: f, cmd: cmd}, nil
}

func (p *linuxPTY) Resize(cols, rows int) error {
	return pty.Setsize(p.File, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

func (p *linuxPTY) Wait() int {
	err := p.cmd.Wait()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

// Hangup sends SIGHUP to the shell's whole session, like closing an SSH
// connection, then SIGKILL for anything that ignored it.
func (p *linuxPTY) Hangup() {
	if p.cmd.Process == nil {
		return
	}
	pgid := p.cmd.Process.Pid // pty.Start makes the shell a session leader
	_ = syscall.Kill(-pgid, syscall.SIGHUP)
	go func() {
		time.Sleep(3 * time.Second)
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}()
}
