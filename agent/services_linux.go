//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"beacle/shared"
)

// --- systemd ------------------------------------------------------------------

func (c *linuxCollector) SystemdUnits() ([]shared.SystemdUnit, error) {
	// D-Bus first: no process spawns, no text to parse back. systemctl stays as
	// the fallback for hosts where the bus is not reachable.
	if units, ok := systemd.Units(); ok {
		noteSystemdPath("dbus", "")
		sort.Slice(units, func(i, j int) bool { return units[i].Name < units[j].Name })
		return units, nil
	}
	// Falling back is invisible from the panel and costs everything the D-Bus
	// path was written to save, so it gets recorded rather than shrugged off.
	noteSystemdPath("systemctl", systemd.LastError())
	return systemdUnitsViaCLI()
}

func systemdUnitsViaCLI() ([]shared.SystemdUnit, error) {
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
	attachMainPIDs(units)
	return units, nil
}

// attachMainPIDs fills in the process behind each running unit, so the panel
// can show a service's CPU and memory instead of a blank column. Only active
// units are asked about — the rest have no process to point at, and the query
// runs on every collection tick.
func attachMainPIDs(units []shared.SystemdUnit) {
	var names []string
	for _, u := range units {
		if u.ActiveState == "active" || u.ActiveState == "activating" {
			names = append(names, u.Name)
		}
	}
	if len(names) == 0 {
		return
	}
	args := append([]string{"show", "--property=Id", "--property=MainPID", "--no-pager"}, names...)
	out, err := exec.Command("systemctl", args...).Output()
	if err != nil {
		return // no PIDs is a missing column, not a failed collection
	}
	// systemctl separates each unit with a blank line but gives no promise
	// about the order of properties inside a block. Reading them as a stream
	// and pairing "the last Id seen" with "the next MainPID" attaches a unit's
	// PID to whichever unit happened to come before it the moment the order
	// flips — which is how services ended up showing the PID, CPU and memory of
	// completely unrelated processes.
	//
	// A block is collected whole and only then interpreted.
	pids := map[string]int{}
	var id string
	pid := 0

	flush := func() {
		if id != "" && pid > 0 {
			pids[id] = pid
		}
		id, pid = "", 0
	}

	for _, line := range strings.Split(string(out), "\n") {
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
	flush() // the final block has no blank line after it

	for i := range units {
		units[i].MainPID = pids[units[i].Name]
	}
}

func (c *linuxCollector) SystemdAction(unit, action string) (string, error) {
	switch action {
	case "start", "stop", "restart":
	default:
		return "", fmt.Errorf("unknown systemd action %q", action)
	}
	if state, ok := systemd.Action(unit, action); ok {
		return state, nil
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

// --- filesystem ----------------------------------------------------------------

// ListDir backs the picker that chooses a working directory and script. It is
// listing only — never file contents — and it hides dotfiles, which are noise
// when you are looking for a bot folder.
func (c *linuxCollector) ListDir(path string) (shared.FSListing, error) {
	if path == "" {
		path = "/root"
		if _, err := os.Stat(path); err != nil {
			path = "/home"
		}
	}
	if !filepath.IsAbs(path) {
		return shared.FSListing{}, fmt.Errorf("path must be absolute")
	}
	path = filepath.Clean(path)

	items, err := os.ReadDir(path)
	if err != nil {
		return shared.FSListing{}, err
	}

	listing := shared.FSListing{Path: path, Parent: filepath.Dir(path)}
	if listing.Parent == path {
		listing.Parent = "" // already at /
	}
	for _, it := range items {
		if strings.HasPrefix(it.Name(), ".") {
			continue
		}
		e := shared.FSEntry{
			Name:  it.Name(),
			Path:  filepath.Join(path, it.Name()),
			IsDir: it.IsDir(),
		}
		if info, err := it.Info(); err == nil {
			e.Mode = info.Mode().String()
			if !it.IsDir() {
				e.Size = uint64(info.Size())
			}
		}
		listing.Entries = append(listing.Entries, e)
	}
	// Directories first, then files, each alphabetical.
	sort.Slice(listing.Entries, func(i, j int) bool {
		a, b := listing.Entries[i], listing.Entries[j]
		if a.IsDir != b.IsDir {
			return a.IsDir
		}
		return a.Name < b.Name
	})
	return listing, nil
}

// --- screen --------------------------------------------------------------------

// screenPayload reports what is executing inside a screen session. screen forks
// a daemon (the pid in `screen -ls`) which owns the window's shell, so the
// payload is a descendant rather than a direct child — an idle session bottoms
// out at the shell itself.
type procRow struct {
	pid, ppid int
	args      string
}

// processTable reads the whole table once from /proc. It used to be a `ps`
// fork, and screenPayload called it per session — three sessions meant three
// full process listings on every poll.
func processTable() []procRow {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var all []procRow
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue // exited while we were walking
		}
		// comm sits in parentheses and can contain spaces, so parse around it.
		closeIdx := strings.LastIndexByte(string(b), ')')
		if closeIdx < 0 {
			continue
		}
		fields := strings.Fields(string(b)[closeIdx+1:])
		if len(fields) < 2 {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		args := ""
		if cb, err := os.ReadFile("/proc/" + e.Name() + "/cmdline"); err == nil {
			// cmdline is NUL-separated, with a trailing NUL.
			args = strings.TrimSpace(strings.ReplaceAll(strings.TrimRight(string(cb), "\x00"), "\x00", " "))
		}
		if args == "" {
			continue // kernel thread: no command line, never a screen payload
		}
		all = append(all, procRow{pid: pid, ppid: ppid, args: args})
	}
	return all
}

func screenPayload(sessionPID int, all []procRow) (int, string) {
	isShell := func(args string) bool {
		first := args
		if i := strings.IndexByte(args, ' '); i > 0 {
			first = args[:i]
		}
		switch filepath.Base(strings.TrimPrefix(first, "-")) {
		case "bash", "sh", "zsh", "dash", "fish", "ash":
			return true
		}
		return false
	}

	// Walk down from the session pid, preferring the deepest non-shell process.
	frontier := []int{sessionPID}
	for depth := 0; depth < 6 && len(frontier) > 0; depth++ {
		var next []int
		for _, parent := range frontier {
			for _, p := range all {
				if p.ppid != parent {
					continue
				}
				if !isShell(p.args) {
					return p.pid, p.args
				}
				next = append(next, p.pid)
			}
		}
		frontier = next
	}
	return 0, ""
}

func (c *linuxCollector) ScreenSessions() ([]shared.ScreenSession, error) {
	out, _ := exec.Command("screen", "-ls").Output()
	// screen -ls exits 1 when there are no sessions; parse whatever we got.
	// One process table for all sessions, read only if there is a session to
	// resolve — a host with no screen sessions should pay nothing.
	var table []procRow
	if strings.Contains(string(out), ".") {
		table = processTable()
	}
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
		childPID, cmd := screenPayload(pid, table)
		sessions = append(sessions, shared.ScreenSession{
			PID:      pid,
			Name:     fields[0][idx+1:],
			Attached: strings.Contains(line, "(Attached)"),
			Created:  created,
			Running:  childPID > 0,
			Command:  cmd,
			ChildPID: childPID,
		})
	}
	return sessions, nil
}

func (c *linuxCollector) ScreenStart(req shared.ScreenStartRequest) error {
	name, err := screenName(req.Name)
	if err != nil {
		return err
	}
	if strings.TrimSpace(req.Command) == "" {
		return fmt.Errorf("command is required")
	}
	// Empty means "wherever the session opens", which for screen is the home
	// directory — the same thing a person sees after `screen -R`.
	dir := strings.TrimSpace(req.Dir)
	if dir == "" || dir == "~" || dir == "~/" {
		dir = ""
	}
	if dir != "" {
		st, err := os.Stat(dir)
		if err != nil || !st.IsDir() {
			return fmt.Errorf("working directory %q does not exist", dir)
		}
	}

	// Refuse to stack a second payload onto a busy session — the UI hides the
	// button, but the agent is what actually has to be sure.
	sessions, _ := c.ScreenSessions()
	for _, s := range sessions {
		if s.Name != name {
			continue
		}
		if s.Running {
			return fmt.Errorf("session %q is already running %s", name, s.Command)
		}
		// Idle session exists: type into it rather than failing. Two separate
		// lines, exactly what a person would type — chaining them with && made
		// a failed cd swallow the command, and any typo in one became a typo
		// in the whole line.
		for _, line := range screenLines(dir, req.Command) {
			out, err := exec.Command("screen", "-S", name, "-p", "0", "-X", "stuff", line+"\n").CombinedOutput()
			if err != nil {
				return fmt.Errorf("screen stuff: %s", strings.TrimSpace(string(out)))
			}
		}
		return nil
	}

	// A fresh session starts a login shell so the environment matches an
	// interactive one, then the same two lines are typed into it.
	out, err := exec.Command("screen", "-dmS", name, "bash", "-l").CombinedOutput()
	if err != nil {
		return fmt.Errorf("screen -dmS: %s", strings.TrimSpace(string(out)))
	}
	// screen needs a moment before its window accepts input.
	time.Sleep(400 * time.Millisecond)
	for _, line := range screenLines(dir, req.Command) {
		out, err := exec.Command("screen", "-S", name, "-p", "0", "-X", "stuff", line+"\n").CombinedOutput()
		if err != nil {
			return fmt.Errorf("screen stuff: %s", strings.TrimSpace(string(out)))
		}
	}
	return nil
}

func (c *linuxCollector) ScreenStop(name string) error {
	if _, err := screenName(name); err != nil {
		return err
	}
	sessions, _ := c.ScreenSessions()
	for _, s := range sessions {
		if s.Name != name {
			continue
		}
		if !s.Running {
			return fmt.Errorf("nothing is running in session %q", name)
		}
		// \003 is Ctrl+C: ask the payload to stop the way a person at the
		// terminal would, instead of killing the session outright.
		out, err := exec.Command("screen", "-S", name, "-p", "0", "-X", "stuff", "\003").CombinedOutput()
		if err != nil {
			return fmt.Errorf("screen stuff ctrl-c: %s", strings.TrimSpace(string(out)))
		}
		return nil
	}
	return fmt.Errorf("session %q not found", name)
}

// ScreenKill removes the session itself, along with whatever is running in it.
// ScreenStop is the polite version that leaves the session open; this is the
// one for a session you are finished with.
func (c *linuxCollector) ScreenKill(name string) error {
	if _, err := screenName(name); err != nil {
		return err
	}
	sessions, _ := c.ScreenSessions()
	found := false
	for _, s := range sessions {
		if s.Name == name {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("session %q not found", name)
	}
	out, err := exec.Command("screen", "-S", name, "-X", "quit").CombinedOutput()
	if err != nil {
		return fmt.Errorf("screen quit: %s", strings.TrimSpace(string(out)))
	}
	// screen leaves the socket behind when the session dies mid-detach, and a
	// dead socket keeps showing up in the list as if the session were still
	// there.
	_ = exec.Command("screen", "-wipe").Run()
	return nil
}

func (c *linuxCollector) ScreenLogs(name string) (string, error) {
	if _, err := screenName(name); err != nil {
		return "", err
	}
	f, err := os.CreateTemp("", "beacle-screen-*.log")
	if err != nil {
		return "", err
	}
	path := f.Name()
	f.Close()
	defer os.Remove(path)

	// -h includes the scrollback buffer, otherwise this is just the visible window.
	out, err := exec.Command("screen", "-S", name, "-p", "0", "-X", "hardcopy", "-h", path).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("screen hardcopy: %s", strings.TrimSpace(string(out)))
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	// hardcopy pads the buffer with blank lines; trim them so the viewer opens
	// on the last real output.
	return strings.TrimRight(string(b), "\n \t"), nil
}
