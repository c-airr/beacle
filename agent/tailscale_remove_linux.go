//go:build linux

package main

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"time"
)

// removeTailscale logs the machine out of the tailnet (so it leaves the
// admin console too) and uninstalls Tailscale with whatever installed it.
// A binary dropped in by hand has no package; its service is stopped and
// disabled instead.
func removeTailscale(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	var log strings.Builder
	run := func(name string, args ...string) error {
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Env = append(cmd.Environ(), "DEBIAN_FRONTEND=noninteractive")
		out, err := cmd.CombinedOutput()
		log.WriteString("$ " + name + " " + strings.Join(args, " ") + "\n")
		log.Write(out)
		return err
	}
	ok := func(name string, args ...string) bool {
		if _, err := exec.LookPath(name); err != nil {
			return false
		}
		return exec.CommandContext(ctx, name, args...).Run() == nil
	}

	if _, err := exec.LookPath("tailscale"); err != nil {
		if !ok("systemctl", "cat", "tailscaled") {
			return "Tailscale is not installed.\n", nil
		}
	} else {
		// Best effort: an already logged-out node is fine.
		_ = run("tailscale", "logout")
	}

	var err error
	switch {
	case ok("dpkg-query", "-W", "-f=${Status}", "tailscale") && dpkgInstalled(ctx):
		err = run("apt-get", "remove", "-y", "tailscale")
	case ok("rpm", "-q", "tailscale"):
		if _, e := exec.LookPath("dnf"); e == nil {
			err = run("dnf", "remove", "-y", "tailscale")
		} else {
			err = run("yum", "remove", "-y", "tailscale")
		}
	case ok("pacman", "-Q", "tailscale"):
		err = run("pacman", "-R", "--noconfirm", "tailscale")
	case ok("apk", "info", "-e", "tailscale"):
		err = run("apk", "del", "tailscale")
	default:
		err = run("systemctl", "disable", "--now", "tailscaled")
	}
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return log.String(), errors.New("removing Tailscale took too long")
		}
		return log.String(), err
	}
	return log.String(), nil
}

// dpkg-query exits 0 for removed-but-configured packages too.
func dpkgInstalled(ctx context.Context) bool {
	out, err := exec.CommandContext(ctx, "dpkg-query", "-W", "-f=${Status}", "tailscale").Output()
	return err == nil && strings.Contains(string(out), "install ok installed")
}
