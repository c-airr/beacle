//go:build linux

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// System package updates (APT/DNF). Listing is cached: a check shells out to
// the package manager and can take a minute on first run, which is too slow
// to do on every panel poll. Applying runs in the background — upgrades take
// minutes and must not hold an HTTP request.

const (
	osUpdateCacheFor = 6 * time.Hour
	osUpdateJobTail  = 32 << 10
)

type osUpdateCache struct {
	mu      sync.Mutex
	at      time.Time
	updates shared.OSUpdates

	jobMu sync.Mutex
	job   shared.OSUpdateJob
	jobOut strings.Builder
}

var osUpdatesState = &osUpdateCache{}

func osPackageManager() string {
	if _, err := exec.LookPath("apt-get"); err == nil {
		return "apt"
	}
	if _, err := exec.LookPath("dnf"); err == nil {
		return "dnf"
	}
	return ""
}

func runCmd(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// LC_ALL=C keeps parsing stable regardless of the VPS locale.
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C", "DEBIAN_FRONTEND=noninteractive")
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return string(out), fmt.Errorf("%s timed out", name)
	}
	return string(out), err
}

func (c *linuxCollector) OSUpdates() (shared.OSUpdates, error) {
	osUpdatesState.mu.Lock()
	if time.Since(osUpdatesState.at) < osUpdateCacheFor && !osUpdatesState.at.IsZero() {
		cached := osUpdatesState.updates
		osUpdatesState.mu.Unlock()
		cached.RebootRequired = rebootRequired()
		return cached, nil
	}
	osUpdatesState.mu.Unlock()

	var res shared.OSUpdates
	var err error
	switch osPackageManager() {
	case "apt":
		res, err = aptUpdates()
	case "dnf":
		res, err = dnfUpdates()
	default:
		return shared.OSUpdates{}, fmt.Errorf("no supported package manager (apt/dnf) found")
	}
	if err != nil {
		return shared.OSUpdates{}, err
	}
	res.RebootRequired = rebootRequired()
	res.CheckedAt = time.Now().UTC().Format(time.RFC3339)

	osUpdatesState.mu.Lock()
	osUpdatesState.updates, osUpdatesState.at = res, time.Now()
	osUpdatesState.mu.Unlock()
	return res, nil
}

// aptListsStale reports whether the package lists are older than the cache
// window. Refreshing them makes one `apt-get update` per check at most.
func aptListsStale() bool {
	lists, _ := filepath.Glob("/var/lib/apt/lists/*")
	var newest time.Time
	for _, f := range lists {
		if st, err := os.Stat(f); err == nil && st.ModTime().After(newest) {
			newest = st.ModTime()
		}
	}
	return time.Since(newest) > osUpdateCacheFor
}

func aptUpdates() (shared.OSUpdates, error) {
	res := shared.OSUpdates{Manager: "apt"}
	if aptListsStale() {
		// Refresh-only: updates the lists, upgrades nothing.
		if _, err := runCmd(2*time.Minute, "apt-get", "update", "-qq"); err != nil {
			return res, fmt.Errorf("apt-get update: %v", err)
		}
	}
	out, err := runCmd(2*time.Minute, "apt", "list", "--upgradable")
	if err != nil {
		return res, fmt.Errorf("apt list: %v", err)
	}
	// Lines look like: openssl/jammy-updates 3.0.2-0ubuntu1.12 amd64 [upgradable from: 3.0.2-0ubuntu1.10]
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Listing") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		name := fields[0]
		if i := strings.IndexByte(name, '/'); i >= 0 {
			name = name[:i]
		}
		latest := fields[1]
		current := ""
		if i := strings.Index(line, "[upgradable from:"); i >= 0 {
			current = strings.TrimSuffix(strings.TrimSpace(line[i+len("[upgradable from:"):]), "]")
		}
		res.Packages = append(res.Packages, shared.OSPackage{
			Name: name, Current: current, Latest: latest,
			Security: aptIsSecurity(name, latest),
		})
	}
	// Ask apt what an upgrade would really install. Whatever it would leave
	// behind is held, or the panel offers an upgrade that changes nothing,
	// forever.
	if sim, err := runCmd(2*time.Minute, "apt-get", "-s", "-o", "Debug::NoLocking=1",
		"upgrade", "--with-new-pkgs"); err == nil {
		would := aptSimulatedInstalls(sim)
		for i := range res.Packages {
			res.Packages[i].Held = !would[res.Packages[i].Name]
		}
	}
	for _, p := range res.Packages {
		if p.Security && !p.Held {
			res.SecurityCount++
		}
	}
	return res, nil
}

// aptSimulatedInstalls reads `apt-get -s upgrade`: one "Inst name [old] (new
// ...)" line per package the upgrade would install.
func aptSimulatedInstalls(out string) map[string]bool {
	m := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "Inst" {
			m[f[1]] = true
		}
	}
	return m
}

// aptIsSecurity checks whether the candidate version comes from a -security
// pocket. One `apt-cache policy` per package sounds heavy, but each call is
// tens of milliseconds and the whole list is cached for hours.
func aptIsSecurity(name, latest string) bool {
	out, err := runCmd(30*time.Second, "apt-cache", "policy", name)
	if err != nil {
		return false
	}
	// Find the candidate stanza, then look for a security origin below it.
	lines := strings.Split(out, "\n")
	inCandidate := false
	for _, l := range lines {
		t := strings.TrimSpace(l)
		if strings.HasPrefix(t, "Candidate:") {
			inCandidate = strings.Contains(t, latest)
			continue
		}
		if inCandidate && strings.HasPrefix(t, "***") {
			inCandidate = true
			continue
		}
		if inCandidate && strings.HasPrefix(t, "0 ") == false && strings.Contains(t, "http") {
			// version table lines; the origin lines follow
			continue
		}
		if inCandidate && (strings.Contains(t, "-security") || strings.Contains(t, "security.debian.org")) {
			return true
		}
		if inCandidate && t != "" && !strings.HasPrefix(l, " ") && !strings.HasPrefix(l, "\t") {
			break
		}
	}
	return false
}

func dnfUpdates() (shared.OSUpdates, error) {
	res := shared.OSUpdates{Manager: "dnf"}
	out, err := runCmd(2*time.Minute, "dnf", "-q", "check-update")
	// NB: dnf exits 100 when updates exist. That is the happy path here.
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); !ok || exitErr.ExitCode() != 100 {
			return res, fmt.Errorf("dnf check-update: %v", err)
		}
	}
	// Lines look like: kernel.x86_64  6.5.0-1  updates
	// Headers and blank lines are skipped; parsing stays loose on purpose.
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || strings.Contains(fields[0], ".") == false {
			continue
		}
		name := fields[0]
		if i := strings.LastIndexByte(name, '.'); i >= 0 {
			name = name[:i]
		}
		res.Packages = append(res.Packages, shared.OSPackage{Name: name, Latest: fields[1]})
	}
	// Security subset, matched by name. Exit 100 just means "there are some".
	secOut, secErr := runCmd(2*time.Minute, "dnf", "-q", "check-update", "--security")
	if secErr == nil || isExitCode(secErr, 100) {
		sec := map[string]bool{}
		for _, line := range strings.Split(secOut, "\n") {
			fields := strings.Fields(line)
			if len(fields) < 3 || strings.Contains(fields[0], ".") == false {
				continue
			}
			name := fields[0]
			if i := strings.LastIndexByte(name, '.'); i >= 0 {
				name = name[:i]
			}
			sec[name] = true
		}
		for i := range res.Packages {
			if sec[res.Packages[i].Name] {
				res.Packages[i].Security = true
				res.SecurityCount++
			}
		}
	}
	return res, nil
}

func isExitCode(err error, code int) bool {
	if exitErr, ok := err.(*exec.ExitError); ok {
		return exitErr.ExitCode() == code
	}
	return false
}

func rebootRequired() bool {
	if _, err := os.Stat("/var/run/reboot-required"); err == nil {
		return true
	}
	if _, err := exec.LookPath("needs-restarting"); err == nil {
		// Exit 1 means a reboot is needed (dnf world).
		if err := exec.Command("needs-restarting", "-r").Run(); err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
				return true
			}
		}
	}
	return false
}

func (c *linuxCollector) OSUpdateApply() error {
	mgr := osPackageManager()
	if mgr == "" {
		return fmt.Errorf("no supported package manager (apt/dnf) found")
	}
	osUpdatesState.jobMu.Lock()
	if osUpdatesState.job.Running {
		osUpdatesState.jobMu.Unlock()
		return fmt.Errorf("an upgrade is already running")
	}
	osUpdatesState.job = shared.OSUpdateJob{Running: true, StartedAt: time.Now().UTC().Format(time.RFC3339)}
	osUpdatesState.jobOut.Reset()
	osUpdatesState.jobMu.Unlock()

	go func() {
		var out string
		var code int
		if mgr == "apt" {
			// --with-new-pkgs: a package that needs a new dependency (the next
			// kernel, a split library) is installed instead of kept back. It
			// still never removes anything; what needs that stays held.
			o, err := runCmd(60*time.Minute, "apt-get", "upgrade", "-y", "--with-new-pkgs",
				"-o", "Dpkg::Options::=--force-confdef", "-o", "Dpkg::Options::=--force-confold")
			out = o
			if err != nil {
				code = 1
			}
		} else {
			o, err := runCmd(60*time.Minute, "dnf", "upgrade", "-y")
			out = o
			if err != nil {
				code = 1
			}
		}
		osUpdatesState.jobMu.Lock()
		osUpdatesState.job.Running = false
		osUpdatesState.job.FinishedAt = time.Now().UTC().Format(time.RFC3339)
		osUpdatesState.job.ExitCode = code
		if len(out) > osUpdateJobTail {
			out = out[len(out)-osUpdateJobTail:]
		}
		osUpdatesState.job.Output = out
		osUpdatesState.jobMu.Unlock()

		// The world changed: drop the package cache so the next read is fresh.
		osUpdatesState.mu.Lock()
		osUpdatesState.at = time.Time{}
		osUpdatesState.mu.Unlock()
	}()
	return nil
}

func (c *linuxCollector) OSUpdateStatus() (shared.OSUpdateJob, error) {
	osUpdatesState.jobMu.Lock()
	defer osUpdatesState.jobMu.Unlock()
	return osUpdatesState.job, nil
}
