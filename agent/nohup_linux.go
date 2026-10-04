//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"beacle/shared"
)

// Detached jobs, the nohup way: no terminal to reattach to, so the agent keeps
// a record of each one. Without it a job started from the panel would be
// unfindable the moment the page refreshed — the exact dead end screen sessions
// used to have, where you could start something and never stop it.
//
// Variables rather than constants so tests can point them at a temp dir.
var (
	nohupStateDir = "/var/lib/beacle/nohup"
	nohupLogDir   = "/var/log/beacle"
)

func nohupStatePath(name string) string { return filepath.Join(nohupStateDir, name+".json") }
func nohupLogPath(name string) string   { return filepath.Join(nohupLogDir, name+".log") }

// pidAlive reports whether a PID is still there. Signal 0 checks for the
// process without touching it.
func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func (c *linuxCollector) NohupJobs() ([]shared.NohupJob, error) {
	entries, err := os.ReadDir(nohupStateDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // nothing started yet is not an error
		}
		return nil, err
	}
	var jobs []shared.NohupJob
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(nohupStateDir, e.Name()))
		if err != nil {
			continue
		}
		var j shared.NohupJob
		if json.Unmarshal(b, &j) != nil {
			continue
		}
		j.Running = jobProcess(j) != nil
		jobs = append(jobs, j)
	}
	sort.Slice(jobs, func(i, k int) bool { return jobs[i].Name < jobs[k].Name })
	return jobs, nil
}

func (c *linuxCollector) NohupStart(req shared.NohupStartRequest) (shared.NohupJob, error) {
	name, err := screenName(req.Name)
	if err != nil {
		return shared.NohupJob{}, err
	}
	if strings.TrimSpace(req.Command) == "" {
		return shared.NohupJob{}, fmt.Errorf("command is required")
	}
	dir := strings.TrimSpace(req.Dir)
	if dir != "" && dir != "~" && dir != "~/" {
		st, err := os.Stat(dir)
		if err != nil || !st.IsDir() {
			return shared.NohupJob{}, fmt.Errorf("working directory %q does not exist", dir)
		}
	} else {
		dir = ""
	}

	// A name already in use by a live job would leave the old PID orphaned in
	// the state file, so the panel could never stop it again.
	if jobs, _ := c.NohupJobs(); jobs != nil {
		for _, j := range jobs {
			if j.Name == name && j.Running {
				return shared.NohupJob{}, fmt.Errorf("job %q is already running (PID %d)", name, j.PID)
			}
		}
	}

	if err := os.MkdirAll(nohupStateDir, 0o755); err != nil {
		return shared.NohupJob{}, err
	}
	if err := os.MkdirAll(nohupLogDir, 0o755); err != nil {
		return shared.NohupJob{}, err
	}

	log := nohupLogPath(name)
	var b strings.Builder
	if dir != "" {
		fmt.Fprintf(&b, "cd %s || exit 1\n", shellQuote(dir))
	}
	// setsid detaches from the agent's session, so restarting the agent cannot
	// take the job down with it. echo $! hands back the PID to remember.
	fmt.Fprintf(&b, "setsid nohup sh -c %s >%s 2>&1 &\necho $!\n",
		shellQuote(strings.TrimSpace(req.Command)), shellQuote(log))

	out, err := exec.Command("sh", "-c", b.String()).Output()
	if err != nil {
		return shared.NohupJob{}, fmt.Errorf("start failed: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return shared.NohupJob{}, fmt.Errorf("started but the PID could not be read: %q", strings.TrimSpace(string(out)))
	}

	job := shared.NohupJob{
		Name:    name,
		PID:     pid,
		Command: strings.TrimSpace(req.Command),
		Dir:     dir,
		LogFile: log,
		Started: time.Now().UTC().Format(time.RFC3339),
		Running: true,
	}
	if st, ok := readProcStat(pid); ok {
		job.BootID = currentBootID()
		job.StartTicks = st.startTicks
	}
	data, _ := json.Marshal(job)
	if err := os.WriteFile(nohupStatePath(name), data, 0o644); err != nil {
		// The job is running but unrecorded, which is worse than not starting:
		// stop it rather than leave something the panel can never reach.
		_ = exec.Command("kill", "-TERM", strconv.Itoa(pid)).Run()
		return shared.NohupJob{}, fmt.Errorf("could not record the job, so it was stopped again: %v", err)
	}
	return job, nil
}

// NohupStop ends a job and forgets it. SIGTERM first so the process can shut
// down on its own terms, SIGKILL only for what ignores it.
func (c *linuxCollector) NohupStop(name string) error {
	if _, err := screenName(name); err != nil {
		return err
	}
	b, err := os.ReadFile(nohupStatePath(name))
	if err != nil {
		return fmt.Errorf("job %q not found", name)
	}
	var j shared.NohupJob
	if err := json.Unmarshal(b, &j); err != nil {
		return fmt.Errorf("job %q has an unreadable record", name)
	}

	// Only a PID that is still this job is signalled. It used to be "any
	// process with that number": a job that had ended — or a record from
	// before a reboot — pointed at whatever the kernel gave the number to
	// next, and Stop took that process down with its whole process group.
	// After a reboot that is dockerd or containerd.
	if leader := jobProcess(j); leader != nil {
		// The process group setsid created, so children go with the job —
		// a job that spawned workers should not leave them behind. Each
		// member is pinned to its start time, so a member that exits during
		// the grace period cannot have its number reused under the KILL.
		group := []procRef{*leader}
		if st, ok := readProcStat(leader.pid); ok && st.pgid == leader.pid {
			group = membersOf(leader.pid, false)
		}
		for _, p := range group {
			p.signal(syscall.SIGTERM)
		}
		for i := 0; i < 20 && leader.still(); i++ {
			time.Sleep(100 * time.Millisecond)
		}
		for _, p := range group {
			p.signal(syscall.SIGKILL)
		}
	}
	// The log stays: it is usually the reason someone wanted the job stopped.
	return os.Remove(nohupStatePath(name))
}

// jobProcess is the job's process if its PID still names it, else nil.
//
// Records since 2.1 pin the process by boot and start time. Older ones only
// have the PID, so they are matched on what the job's process always has:
// its output redirected to the job's log file — a stranger that inherited
// the number does not write to /var/log/beacle/<job>.log.
func jobProcess(j shared.NohupJob) *procRef {
	if !pidAlive(j.PID) {
		return nil
	}
	st, ok := readProcStat(j.PID)
	if !ok {
		return nil
	}
	if j.StartTicks != 0 {
		if j.BootID != currentBootID() || st.startTicks != j.StartTicks {
			return nil
		}
	} else if !fdPointsAt(j.PID, j.LogFile) {
		return nil
	}
	return &procRef{pid: j.PID, start: st.startTicks}
}

func (c *linuxCollector) NohupLogs(name string) (string, error) {
	if _, err := screenName(name); err != nil {
		return "", err
	}
	out, err := exec.Command("tail", "-n", "500", nohupLogPath(name)).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("no log for %q yet", name)
	}
	if strings.TrimSpace(string(out)) == "" {
		return "(no output yet)", nil
	}
	return string(out), nil
}
