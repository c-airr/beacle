//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// A PID names a process only while it lives: once it exits, the kernel hands
// the number to the next process that starts — after a reboot, typically to
// dockerd or containerd. Anything the agent remembers by PID and later
// signals is therefore checked against the process's start time first, so a
// stale number never reaches a stranger.

// procStat is the part of /proc/<pid>/stat the agent needs.
type procStat struct {
	pgid, sid  int
	startTicks uint64 // clock ticks after boot
}

func readProcStat(pid int) (procStat, bool) {
	if pid <= 0 {
		return procStat{}, false
	}
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return procStat{}, false
	}
	// comm is in parentheses and may contain spaces; fields after it start
	// at "state" (field 3).
	i := strings.LastIndexByte(string(b), ')')
	if i < 0 {
		return procStat{}, false
	}
	f := strings.Fields(string(b)[i+1:])
	if len(f) < 20 {
		return procStat{}, false
	}
	pgid, err1 := strconv.Atoi(f[2])
	sid, err2 := strconv.Atoi(f[3])
	start, err3 := strconv.ParseUint(f[19], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil {
		return procStat{}, false
	}
	return procStat{pgid: pgid, sid: sid, startTicks: start}, true
}

// currentBootID tells one boot from the next: start times count from boot,
// so they only mean something together with it.
func currentBootID() string {
	b, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// procRef is a process pinned to its start time.
type procRef struct {
	pid   int
	start uint64
}

// still reports whether the process is the same one that was pinned.
func (r procRef) still() bool {
	st, ok := readProcStat(r.pid)
	return ok && st.startTicks == r.start
}

// signal delivers sig only if the PID still names the pinned process.
func (r procRef) signal(sig syscall.Signal) {
	if r.pid <= 1 || r.pid == os.Getpid() || !r.still() {
		return
	}
	_ = syscall.Kill(r.pid, sig)
}

// membersOf lists the live processes whose process group (or session, with
// bySession) is id, pinned to their start times.
func membersOf(id int, bySession bool) []procRef {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	var out []procRef
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		st, ok := readProcStat(pid)
		if !ok {
			continue
		}
		key := st.pgid
		if bySession {
			key = st.sid
		}
		if key == id {
			out = append(out, procRef{pid: pid, start: st.startTicks})
		}
	}
	return out
}

// fdPointsAt reports whether one of the process's stdout/stderr is path.
func fdPointsAt(pid int, path string) bool {
	if path == "" {
		return false
	}
	for _, fd := range []string{"1", "2"} {
		if target, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/fd/" + fd); err == nil && target == path {
			return true
		}
	}
	return false
}
