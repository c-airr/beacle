//go:build linux

package main

import (
	"context"
	"sync"
	"time"

	sd "github.com/coreos/go-systemd/v22/dbus"

	"beacle/shared"
)

// systemdBus is the agent's connection to systemd.
//
// The status loop used to shell out three times per tick: list-units --all,
// list-unit-files, and a show for the main PIDs. Each of those is a process
// spawn plus systemd doing the same D-Bus work internally and formatting it as
// text for us to parse back. On a small VPS that was enough to put a core at
// 50% every few seconds.
//
// Talking to systemd directly costs one connection, held open, and no forks at
// all. Nothing here ever calls daemon-reload: reloading is what a unit file
// change needs, not what reading status needs, and doing it on a timer makes
// systemd re-parse every unit on disk for no reason.
type systemdBus struct {
	mu   sync.Mutex
	conn *sd.Conn

	// Unit *files* only change when something writes to /etc/systemd, which is
	// not something a status poll can cause. Cached well past the poll interval.
	fileStates   map[string]string
	fileStatesAt time.Time
}

var systemd = &systemdBus{}

const unitFileCacheFor = 5 * time.Minute

// connect returns a live connection, dialing on first use and after a drop.
// A failure is not fatal: callers fall back to systemctl, which keeps the agent
// working on hosts where the bus is not reachable.
func (s *systemdBus) connect() (*sd.Conn, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn != nil && s.conn.Connected() {
		return s.conn, nil
	}
	if s.conn != nil {
		s.conn.Close()
		s.conn = nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := sd.NewSystemConnectionContext(ctx)
	if err != nil {
		return nil, err
	}
	s.conn = conn
	return conn, nil
}

// unitFileStates maps unit name to enabled/disabled/static. Cached, because
// this is the expensive half of the old implementation and the answer changes
// only when someone runs enable or disable.
func (s *systemdBus) unitFileStates(ctx context.Context, conn *sd.Conn) map[string]string {
	s.mu.Lock()
	if s.fileStates != nil && time.Since(s.fileStatesAt) < unitFileCacheFor {
		cached := s.fileStates
		s.mu.Unlock()
		return cached
	}
	s.mu.Unlock()

	files, err := conn.ListUnitFilesByPatternsContext(ctx, nil, []string{"*.service"})
	if err != nil {
		return nil
	}
	out := make(map[string]string, len(files))
	for _, f := range files {
		// Path is absolute; the unit name is its last segment.
		name := f.Path
		for i := len(name) - 1; i >= 0; i-- {
			if name[i] == '/' {
				name = name[i+1:]
				break
			}
		}
		out[name] = f.Type
	}

	s.mu.Lock()
	s.fileStates = out
	s.fileStatesAt = time.Now()
	s.mu.Unlock()
	return out
}

// InvalidateUnitFiles drops the cache after something that can actually change
// it — enabling a unit, or writing a unit file.
func (s *systemdBus) InvalidateUnitFiles() {
	s.mu.Lock()
	s.fileStates = nil
	s.mu.Unlock()
}

// Units lists service units with their state and main PID. Returns ok=false
// when the bus is unavailable, so the caller can fall back.
func (s *systemdBus) Units() ([]shared.SystemdUnit, bool) {
	conn, err := s.connect()
	if err != nil {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// ListUnits returns loaded units. Units that exist on disk but have never
	// been loaded come from the unit-file list below, so nothing is lost by not
	// asking for --all here.
	list, err := conn.ListUnitsByPatternsContext(ctx, nil, []string{"*.service"})
	if err != nil {
		return nil, false
	}
	fileStates := s.unitFileStates(ctx, conn)

	units := make([]shared.SystemdUnit, 0, len(list))
	seen := make(map[string]bool, len(list))
	for _, u := range list {
		seen[u.Name] = true
		unit := shared.SystemdUnit{
			Name:        u.Name,
			Description: u.Description,
			LoadState:   u.LoadState,
			ActiveState: u.ActiveState,
			SubState:    u.SubState,
			Enabled:     fileStates[u.Name],
		}
		// Only running units have a process worth asking about, and each of
		// these is one small property read rather than a spawn.
		if u.ActiveState == "active" || u.ActiveState == "activating" {
			if props, err := conn.GetUnitTypePropertiesContext(ctx, u.Name, "Service"); err == nil {
				if pid, ok := props["MainPID"].(uint32); ok {
					unit.MainPID = int(pid)
				}
			}
		}
		units = append(units, unit)
	}

	// Installed but not loaded: shown so the panel can still offer to start
	// them, the way `list-units --all` used to.
	for name, state := range fileStates {
		if seen[name] {
			continue
		}
		units = append(units, shared.SystemdUnit{
			Name:        name,
			LoadState:   "not-loaded",
			ActiveState: "inactive",
			SubState:    "dead",
			Enabled:     state,
		})
	}
	return units, true
}

// Action runs start/stop/restart over the bus and reports the resulting state.
func (s *systemdBus) Action(unit, action string) (string, bool) {
	conn, err := s.connect()
	if err != nil {
		return "", false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	done := make(chan string, 1)
	switch action {
	case "start":
		_, err = conn.StartUnitContext(ctx, unit, "replace", done)
	case "stop":
		_, err = conn.StopUnitContext(ctx, unit, "replace", done)
	case "restart":
		_, err = conn.RestartUnitContext(ctx, unit, "replace", done)
	default:
		return "", false
	}
	if err != nil {
		return "", false
	}
	select {
	case <-done:
	case <-ctx.Done():
		return "", false
	}

	props, err := conn.GetUnitPropertiesContext(ctx, unit)
	if err != nil {
		return "", true
	}
	state, _ := props["ActiveState"].(string)
	return state, true
}
