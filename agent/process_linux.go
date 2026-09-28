//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// KillProcess delivers SIGTERM ("term") or SIGKILL ("kill") to a process by
// PID. Two refusals are hardcoded: PID 1 (init — signalling it reboots or
// kills the machine depending on the signal) and the agent's own PID
// (suicide by typo in the panel).
func (c *linuxCollector) KillProcess(pid int, signal string) error {
	if pid <= 1 {
		return fmt.Errorf("refusing to signal PID %d", pid)
	}
	if pid == os.Getpid() {
		return fmt.Errorf("refusing to kill the agent itself (PID %d)", pid)
	}
	var sig syscall.Signal
	switch signal {
	case "", "term":
		sig = syscall.SIGTERM
	case "kill":
		sig = syscall.SIGKILL
	default:
		return fmt.Errorf("unknown signal %q (want term or kill)", signal)
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	if err := proc.Signal(sig); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return fmt.Errorf("process %d no longer exists", pid)
		}
		if errors.Is(err, syscall.EPERM) {
			return fmt.Errorf("no permission to signal PID %d", pid)
		}
		return err
	}
	return nil
}
