//go:build linux

package main

import (
	"strconv"
	"strings"
	"testing"

	"beacle/shared"
)

// parseShowPIDs is the body of attachMainPIDs, split out so the parsing can be
// tested without a systemd to talk to.
func parseShowPIDs(out string) map[string]int {
	pids := map[string]int{}
	var id string
	pid := 0

	flush := func() {
		if id != "" && pid > 0 {
			pids[id] = pid
		}
		id, pid = "", 0
	}

	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			flush()
			continue
		}
		if v, ok := strings.CutPrefix(line, "Id="); ok {
			id = v
			continue
		}
		if v, ok := strings.CutPrefix(line, "MainPID="); ok {
			if n, err := strconv.Atoi(v); err == nil {
				pid = n
			}
		}
	}
	flush()
	return pids
}

// systemctl gives no promise about the order of properties inside a block.
// Reading them as a stream and pairing "the last Id seen" with "the next
// MainPID" attaches a unit's PID to whichever unit came before it — which is
// how the panel ended up showing docker.service running under fail2ban's PID,
// with fail2ban's CPU and memory next to it.
func TestMainPIDParsingIsOrderIndependent(t *testing.T) {
	idFirst := "Id=docker.service\nMainPID=968\n\nId=dbus.service\nMainPID=746\n\nId=fail2ban.service\nMainPID=1046210\n"
	pidFirst := "MainPID=968\nId=docker.service\n\nMainPID=746\nId=dbus.service\n\nMainPID=1046210\nId=fail2ban.service\n"

	want := map[string]int{
		"docker.service":   968,
		"dbus.service":     746,
		"fail2ban.service": 1046210,
	}

	for name, out := range map[string]string{"Id first": idFirst, "MainPID first": pidFirst} {
		got := parseShowPIDs(out)
		for unit, pid := range want {
			if got[unit] != pid {
				t.Errorf("%s: %s = %d, want %d — a unit is wearing another process's PID",
					name, unit, got[unit], pid)
			}
		}
		if len(got) != len(want) {
			t.Errorf("%s: got %d units, want %d", name, len(got), len(want))
		}
	}
}

// Units that are not running report MainPID=0, which must not be handed out as
// if it were a process.
func TestMainPIDZeroIsNotRecorded(t *testing.T) {
	got := parseShowPIDs("Id=idle.service\nMainPID=0\n\nId=live.service\nMainPID=42\n")
	if _, ok := got["idle.service"]; ok {
		t.Error("a stopped unit was given a PID")
	}
	if got["live.service"] != 42 {
		t.Errorf("live.service = %d, want 42", got["live.service"])
	}
}

// The last block has no blank line after it, so it only survives if the parser
// flushes at the end.
func TestLastBlockIsNotDropped(t *testing.T) {
	got := parseShowPIDs("Id=first.service\nMainPID=1\n\nId=last.service\nMainPID=2")
	if got["last.service"] != 2 {
		t.Errorf("last.service = %d, want 2 — the final block was dropped", got["last.service"])
	}
}

// attachMainPIDs must leave units it knows nothing about at zero rather than
// borrowing a neighbour's PID.
func TestUnknownUnitsKeepZero(t *testing.T) {
	units := []shared.SystemdUnit{
		{Name: "a.service", ActiveState: "inactive"},
		{Name: "b.service", ActiveState: "inactive"},
	}
	attachMainPIDs(units) // no active units, so systemctl is never run
	for _, u := range units {
		if u.MainPID != 0 {
			t.Errorf("%s got PID %d without ever being active", u.Name, u.MainPID)
		}
	}
}
