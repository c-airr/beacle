//go:build linux

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"beacle/shared"
)

func useTempNohupDirs(t *testing.T) {
	t.Helper()
	oldState, oldLog := nohupStateDir, nohupLogDir
	nohupStateDir = filepath.Join(t.TempDir(), "state")
	nohupLogDir = filepath.Join(t.TempDir(), "log")
	t.Cleanup(func() { nohupStateDir, nohupLogDir = oldState, oldLog })
}

// startBystander runs a process in a session of its own — like dockerd or
// containerd, which systemd starts as session and group leaders.
func startBystander(t *testing.T) *exec.Cmd {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	return cmd
}

func writeJob(t *testing.T, j shared.NohupJob) {
	t.Helper()
	if err := os.MkdirAll(nohupStateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(j)
	if err := os.WriteFile(nohupStatePath(j.Name), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func alive(cmd *exec.Cmd) bool {
	// Reap if it died, then ask.
	var ws syscall.WaitStatus
	pid, _ := syscall.Wait4(cmd.Process.Pid, &ws, syscall.WNOHANG, nil)
	return pid == 0
}

// A job that ended long ago — or before a reboot — leaves its record behind
// with a PID the kernel has since handed to something else. Stopping or
// removing that record must not signal the stranger: that is how Docker got
// killed from the nohup tab.
func TestNohupStopLeavesAReusedPIDAlone(t *testing.T) {
	useTempNohupDirs(t)
	stranger := startBystander(t)

	// A legacy record (no start time) and a current one (start time of a
	// process long gone) both point at the stranger's PID.
	for _, j := range []shared.NohupJob{
		{Name: "legacy", PID: stranger.Process.Pid, Command: "python3 bot.py", LogFile: filepath.Join(nohupLogDir, "legacy.log")},
		{Name: "current", PID: stranger.Process.Pid, Command: "python3 bot.py", LogFile: filepath.Join(nohupLogDir, "current.log"), BootID: currentBootID(), StartTicks: 1},
	} {
		writeJob(t, j)
		c := &linuxCollector{}

		jobs, err := c.NohupJobs()
		if err != nil {
			t.Fatal(err)
		}
		for _, got := range jobs {
			if got.Name == j.Name && got.Running {
				t.Errorf("%s: a stranger holding the PID is reported as the job running", j.Name)
			}
		}
		if err := c.NohupStop(j.Name); err != nil {
			t.Fatalf("%s: stop: %v", j.Name, err)
		}
		time.Sleep(300 * time.Millisecond)
		if !alive(stranger) {
			t.Fatalf("%s: stopping a dead job's record killed an unrelated process", j.Name)
		}
		if _, err := os.Stat(nohupStatePath(j.Name)); !os.IsNotExist(err) {
			t.Errorf("%s: record should be gone", j.Name)
		}
	}
}

// The real thing still works: a job started from the panel is reported as
// running and stopping it ends it and its children.
func TestNohupStartStopRealJob(t *testing.T) {
	useTempNohupDirs(t)
	c := &linuxCollector{}
	j, err := c.NohupStart(shared.NohupStartRequest{Name: "job", Command: "sleep 60 & sleep 60"})
	if err != nil {
		t.Fatal(err)
	}
	jobs, _ := c.NohupJobs()
	if len(jobs) != 1 || !jobs[0].Running {
		t.Fatalf("started job not reported as running: %+v", jobs)
	}
	if err := c.NohupStop("job"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for pidAlive(j.PID) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if pidAlive(j.PID) {
		t.Fatal("job still running after stop")
	}
}

// screen matches -S by prefix: deleting "bc-web" used to be able to hit
// "bc-webapp" too, or fail as ambiguous. Each command now names one session.
func TestScreenKillTouchesOnlyTheNamedSession(t *testing.T) {
	if !screenAvailable() {
		t.Skip("screen not installed")
	}
	c := &linuxCollector{}
	for _, n := range []string{"bc-web", "bc-webapp"} {
		if out, err := exec.Command("screen", "-dmS", n, "sleep", "60").CombinedOutput(); err != nil {
			t.Fatalf("screen: %v %s", err, out)
		}
	}
	t.Cleanup(func() {
		_ = exec.Command("screen", "-S", "bc-webapp", "-X", "quit").Run()
		_ = exec.Command("screen", "-S", "bc-web", "-X", "quit").Run()
	})
	time.Sleep(300 * time.Millisecond)
	if err := c.ScreenKill("bc-web"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	sessions, _ := c.ScreenSessions()
	var names []string
	for _, s := range sessions {
		names = append(names, s.Name)
	}
	has := func(n string) bool {
		for _, x := range names {
			if x == n {
				return true
			}
		}
		return false
	}
	if has("bc-web") || !has("bc-webapp") {
		t.Fatalf("after deleting bc-web the sessions are %v", names)
	}
}
