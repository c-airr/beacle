//go:build linux

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"beacle/shared"
)

// --- systemd ------------------------------------------------------------------

func (c *linuxCollector) SystemdUnits() ([]shared.SystemdUnit, error) {
	out, err := exec.Command("systemctl", "list-units", "--type=service", "--all",
		"--no-legend", "--no-pager", "--plain").Output()
	if err != nil {
		return nil, fmt.Errorf("systemctl: %w", err)
	}
	enabled := map[string]string{}
	if eout, err := exec.Command("systemctl", "list-unit-files", "--type=service",
		"--no-legend", "--no-pager", "--plain").Output(); err == nil {
		for _, line := range strings.Split(string(eout), "\n") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				enabled[f[0]] = f[1]
			}
		}
	}
	var units []shared.SystemdUnit
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 || !strings.HasSuffix(f[0], ".service") {
			continue
		}
		units = append(units, shared.SystemdUnit{
			Name:        f[0],
			LoadState:   f[1],
			ActiveState: f[2],
			SubState:    f[3],
			Description: strings.Join(f[4:], " "),
			Enabled:     enabled[f[0]],
		})
	}
	return units, nil
}

func (c *linuxCollector) SystemdAction(unit, action string) (string, error) {
	switch action {
	case "start", "stop", "restart":
	default:
		return "", fmt.Errorf("unknown systemd action %q", action)
	}
	out, err := exec.Command("systemctl", action, unit).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("systemctl %s %s: %s", action, unit, strings.TrimSpace(string(out)))
	}
	st, _ := exec.Command("systemctl", "is-active", unit).Output()
	return strings.TrimSpace(string(st)), nil
}

func (c *linuxCollector) SystemdLogs(unit string, lines int) (string, error) {
	if lines <= 0 {
		lines = 200
	}
	out, err := exec.Command("journalctl", "-u", unit, "-n", strconv.Itoa(lines),
		"--no-pager", "--output=short-iso").Output()
	if err != nil {
		return "", fmt.Errorf("journalctl: %w", err)
	}
	return string(out), nil
}

// --- screen --------------------------------------------------------------------

func (c *linuxCollector) ScreenSessions() ([]shared.ScreenSession, error) {
	out, _ := exec.Command("screen", "-ls").Output()
	// screen -ls exits 1 when there are no sessions; parse whatever we got.
	var sessions []shared.ScreenSession
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		// format: "12345.name\t(01/02/2026 03:04:05 PM)\t(Detached)"
		if !strings.Contains(line, "(") || !strings.Contains(line, ".") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		idx := strings.Index(fields[0], ".")
		if idx <= 0 {
			continue
		}
		pid, err := strconv.Atoi(fields[0][:idx])
		if err != nil {
			continue
		}
		created := ""
		if s := strings.Index(line, "("); s >= 0 {
			if e := strings.Index(line[s:], ")"); e > 0 {
				created = line[s+1 : s+e]
			}
		}
		sessions = append(sessions, shared.ScreenSession{
			PID:      pid,
			Name:     fields[0][idx+1:],
			Attached: strings.Contains(line, "(Attached)"),
			Created:  created,
		})
	}
	return sessions, nil
}
