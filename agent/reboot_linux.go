//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"beacle/shared"
)

// Reboot and restore. screen sessions die with the machine and the agent
// keeps no record of them, so a reboot with restore snapshots each session
// (payload argv + cwd) plus the names of running nohup jobs into a manifest.
// nohup jobs already have state files, so names are enough — the stale PIDs
// inside are discarded and the jobs relaunched. The agent starts at boot
// from systemd, consumes the manifest once, and leaves a result file the
// panel reads to show what came back.

const (
	restoreDir      = "/var/lib/beacle"
	restoreManifest = restoreDir + "/restore.json"
	restoreResult   = restoreDir + "/restore-result.json"
)

// argvToShell rebuilds a runnable shell line from /proc cmdline argv. Arguments
// are quoted only when they need it, so `python3 main.py` stays readable
// while paths with spaces still survive.
func argvToShell(argv []string) string {
	var parts []string
	for _, a := range argv {
		if a == "" {
			continue
		}
		if strings.ContainsAny(a, " \t\n\"'\\$`!*?|<>(){};&") {
			parts = append(parts, shellQuote(a))
		} else {
			parts = append(parts, a)
		}
	}
	return strings.Join(parts, " ")
}

func procArgv(pid int) []string {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil
	}
	var argv []string
	for _, a := range strings.Split(string(raw), "\x00") {
		if a != "" {
			argv = append(argv, a)
		}
	}
	return argv
}

func procCwd(pid int) string {
	cwd, err := os.Readlink(fmt.Sprintf("/proc/%d/cwd", pid))
	if err != nil {
		return ""
	}
	// Deleted directories (a payload started somewhere since removed) would
	// fail the restore's cd — fall back to the home default instead.
	if strings.Contains(cwd, " (deleted)") {
		return ""
	}
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		return ""
	}
	return cwd
}

func (c *linuxCollector) snapshotScreens() []shared.ScreenRestoreSpec {
	sessions, err := c.ScreenSessions()
	if err != nil {
		return nil
	}
	var out []shared.ScreenRestoreSpec
	for _, s := range sessions {
		spec := shared.ScreenRestoreSpec{Name: s.Name}
		if !s.Running || s.ChildPID <= 0 {
			spec.Idle = true
			out = append(out, spec)
			continue
		}
		argv := procArgv(s.ChildPID)
		if len(argv) == 0 {
			// Payload already gone between listing and snapshotting —
			// recreate the session bare rather than fail the whole reboot.
			spec.Idle = true
			out = append(out, spec)
			continue
		}
		spec.Command = argvToShell(argv)
		spec.Dir = procCwd(s.ChildPID)
		out = append(out, spec)
	}
	return out
}

func (c *linuxCollector) snapshotNohup() []string {
	jobs, err := c.NohupJobs()
	if err != nil {
		return nil
	}
	var out []string
	for _, j := range jobs {
		if j.Running {
			out = append(out, j.Name)
		}
	}
	return out
}

func scheduleHostAction(reboot bool) {
	go func() {
		// Let the HTTP response flush before the machine goes away.
		time.Sleep(2 * time.Second)
		if reboot {
			for _, argv := range [][]string{
				{"systemctl", "reboot"},
				{"reboot"},
				{"shutdown", "-r", "now"},
			} {
				if err := exec.Command(argv[0], argv[1:]...).Run(); err == nil {
					return
				}
			}
			return
		}
		for _, argv := range [][]string{
			{"systemctl", "poweroff"},
			{"poweroff"},
			{"shutdown", "-h", "now"},
		} {
			if err := exec.Command(argv[0], argv[1:]...).Run(); err == nil {
				return
			}
		}
	}()
}

func (c *linuxCollector) Reboot(restore bool) (shared.RebootResult, error) {
	var res shared.RebootResult
	if restore {
		m := shared.RestoreManifest{CreatedAt: time.Now().UTC().Format(time.RFC3339)}
		m.Screens = c.snapshotScreens()
		m.Nohup = c.snapshotNohup()
		if err := os.MkdirAll(restoreDir, 0o755); err != nil {
			return res, err
		}
		data, _ := json.MarshalIndent(m, "", "  ")
		if err := os.WriteFile(restoreManifest, data, 0o644); err != nil {
			return res, err
		}
		res.ScreensQueued = len(m.Screens)
		res.NohupQueued = len(m.Nohup)
	} else {
		// An explicit reboot without restore must not resurrect an older
		// manifest — e.g. from a previous reboot that never completed.
		_ = os.Remove(restoreManifest)
	}
	_ = os.Remove(restoreResult)
	scheduleHostAction(true)
	res.OK = true
	return res, nil
}

func (c *linuxCollector) Poweroff() error {
	_ = os.Remove(restoreManifest)
	_ = os.Remove(restoreResult)
	scheduleHostAction(false)
	return nil
}

func (c *linuxCollector) RestoreStatus() (shared.RestoreResult, error) {
	raw, err := os.ReadFile(restoreResult)
	if err != nil {
		return shared.RestoreResult{}, nil
	}
	var res shared.RestoreResult
	if err := json.Unmarshal(raw, &res); err != nil {
		return shared.RestoreResult{}, nil
	}
	return res, nil
}

// maybeRestoreSessions runs once at agent startup. No manifest, no work —
// the common case is a plain agent restart, which must not touch anything.
func maybeRestoreSessions(col Collector) {
	raw, err := os.ReadFile(restoreManifest)
	if err != nil {
		return
	}
	var m shared.RestoreManifest
	res := shared.RestoreResult{Restored: true, RestoredAt: time.Now().UTC().Format(time.RFC3339)}
	if err := json.Unmarshal(raw, &m); err != nil {
		res.Restored = false
		writeRestoreResult(res)
		_ = os.Remove(restoreManifest)
		return
	}
	// The system is still coming up (network, mounts); sessions that need
	// either would fail instantly. Agents that start late pay nothing extra.
	time.Sleep(10 * time.Second)

	for _, s := range m.Screens {
		item := shared.RestoreItemResult{Name: s.Name, OK: true}
		if err := restoreScreen(col, s); err != nil {
			item.OK = false
			item.Error = err.Error()
		}
		res.Screens = append(res.Screens, item)
	}
	for _, name := range m.Nohup {
		item := shared.RestoreItemResult{Name: name, OK: true}
		if err := restoreNohup(col, name); err != nil {
			item.OK = false
			item.Error = err.Error()
		}
		res.Nohup = append(res.Nohup, item)
	}
	writeRestoreResult(res)
	_ = os.Remove(restoreManifest)
}

func writeRestoreResult(res shared.RestoreResult) {
	data, _ := json.MarshalIndent(res, "", "  ")
	_ = os.MkdirAll(restoreDir, 0o755)
	_ = os.WriteFile(restoreResult, data, 0o644)
}

func restoreScreen(col Collector, s shared.ScreenRestoreSpec) error {
	if _, err := screenName(s.Name); err != nil {
		return err
	}
	if s.Idle || strings.TrimSpace(s.Command) == "" {
		out, err := exec.Command("screen", "-dmS", s.Name).CombinedOutput()
		if err != nil {
			return fmt.Errorf("screen -dmS: %s", strings.TrimSpace(string(out)))
		}
		return nil
	}
	dir := s.Dir
	if dir != "" {
		if st, err := os.Stat(dir); err != nil || !st.IsDir() {
			dir = ""
		}
	}
	return col.ScreenStart(shared.ScreenStartRequest{Name: s.Name, Dir: dir, Command: s.Command})
}

func restoreNohup(col Collector, name string) error {
	if _, err := screenName(name); err != nil {
		return err
	}
	raw, err := os.ReadFile(nohupStatePath(name))
	if err != nil {
		return fmt.Errorf("state file gone: %v", err)
	}
	var old shared.NohupJob
	if err := json.Unmarshal(raw, &old); err != nil {
		return fmt.Errorf("unreadable state file")
	}
	// The recorded PID belongs to the previous boot. Remove first so a PID
	// recycled by the new boot cannot read as "already running".
	_ = os.Remove(nohupStatePath(name))
	_, err = col.NohupStart(shared.NohupStartRequest{Name: name, Dir: old.Dir, Command: old.Command})
	return err
}
