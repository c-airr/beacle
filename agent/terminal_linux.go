//go:build linux

package main

import (
	"errors"
	"os"
	"os/exec"
	"os/user"
	"syscall"
	"time"

	"github.com/creack/pty"
)

type linuxPTY struct {
	*os.File // PTY master
	cmd      *exec.Cmd
}

// loginShell picks root's shell, falling back to whatever exists.
func loginShell() string {
	for _, sh := range []string{os.Getenv("SHELL"), "/bin/bash", "/bin/sh"} {
		if sh == "" {
			continue
		}
		if _, err := os.Stat(sh); err == nil {
			return sh
		}
	}
	return "/bin/sh"
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
