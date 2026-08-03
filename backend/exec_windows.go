//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// createNoWindow is CREATE_NO_WINDOW. The backend is linked with -H windowsgui
// so it owns no console; when a process like that starts a console program,
// Windows helpfully makes one for it. That is the black window flashing on
// screen every time the backend asks tailscale a question.
const createNoWindow = 0x08000000

// hideConsole keeps a child process from painting a console window. Every
// exec in this package goes through it — a background probe has no business
// stealing focus.
func hideConsole(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	return cmd
}
