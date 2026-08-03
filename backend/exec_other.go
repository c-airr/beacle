//go:build !windows

package main

import "os/exec"

// hideConsole is a no-op away from Windows: nothing pops up a console window
// there, so the call sites stay identical on every platform.
func hideConsole(cmd *exec.Cmd) *exec.Cmd { return cmd }
