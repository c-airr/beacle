//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// Scheduled tasks: root's crontab (read-write), /etc/crontab + /etc/cron.d/*
// (read-only) and systemd timers (read-only). Only root's own crontab is
// mutated, through `crontab -`, so package-owned files are never touched.

var cronMu sync.Mutex

var (
	cronEnvRe  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*\s*=`)
	cronNumRe  = regexp.MustCompile(`^[0-9]+$`)
	cronNameRe = map[int]map[string]bool{
		3: {"jan": true, "feb": true, "mar": true, "apr": true, "may": true, "jun": true,
			"jul": true, "aug": true, "sep": true, "oct": true, "nov": true, "dec": true},
		4: {"sun": true, "mon": true, "tue": true, "wed": true, "thu": true, "fri": true, "sat": true},
	}
	// field bounds: minute hour dom month dow
	cronBounds = [5][2]int{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}}
)

var cronShortcuts = map[string][5]string{
	"@yearly":  {"0", "0", "1", "1", "*"},
	"@annually": {"0", "0", "1", "1", "*"},
	"@monthly": {"0", "0", "1", "*", "*"},
	"@weekly":  {"0", "0", "*", "*", "0"},
	"@daily":   {"0", "0", "*", "*", "*"},
	"@midnight": {"0", "0", "*", "*", "*"},
	"@hourly":  {"0", "*", "*", "*", "*"},
}

func cronAvailable() bool {
	_, err := exec.LookPath("crontab")
	return err == nil
}

func loadCrontab() ([]string, error) {
	out, err := runCmd(10*time.Second, "crontab", "-l")
	if err != nil {
		// Fresh hosts have no crontab at all — that is an empty list, not a failure.
		if strings.Contains(strings.ToLower(out), "no crontab") {
			return nil, nil
		}
		return nil, err
	}
	lines := strings.Split(out, "\n")
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines, nil
}

func saveCrontab(lines []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "crontab", "-")
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	cmd.Stdin = bytes.NewBufferString(strings.Join(lines, "\n") + "\n")
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("crontab timed out")
	}
	if err != nil {
		return fmt.Errorf("crontab: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// splitCronFields cuts a crontab line into its leading whitespace-separated
// fields, returning the first n fields plus the remainder as one string.
func splitCronFields(line string, n int) ([]string, string, bool) {
	fields := strings.Fields(line)
	if len(fields) < n+1 {
		return nil, "", false
	}
	rest := line
	for i := 0; i < n; i++ {
		idx := strings.Index(rest, fields[i])
		rest = strings.TrimSpace(rest[idx+len(fields[i]):])
	}
	return fields[:n], rest, true
}

func parseCronLine(line string, withUser bool) (shared.CronEntrySpec, string, bool) {
	spec := shared.CronEntrySpec{}
	rest := strings.TrimSpace(line)
	if rest == "" || strings.HasPrefix(rest, "#") || cronEnvRe.MatchString(rest) {
		return spec, "", false
	}
	if strings.HasPrefix(rest, "@") {
		parts := strings.Fields(rest)
		if len(parts) < 2 {
			return spec, "", false
		}
		tail := strings.Join(parts[1:], " ")
		user := ""
		if withUser {
			u, cmd, ok := splitCronFields(tail, 1)
			if !ok {
				return spec, "", false
			}
			user, tail = u[0], cmd
		}
		if parts[0] == "@reboot" {
			// @reboot has no time fields; surface it with a marker.
			spec = shared.CronEntrySpec{Minute: "@reboot", Command: tail}
			return spec, user, true
		}
		exp, ok := cronShortcuts[strings.ToLower(parts[0])]
		if !ok {
			return spec, "", false
		}
		spec.Minute, spec.Hour, spec.DayMonth, spec.Month, spec.DayWeek = exp[0], exp[1], exp[2], exp[3], exp[4]
		spec.Command = tail
		return spec, user, true
	}
	timeFields, tail, ok := splitCronFields(rest, 5)
	if !ok {
		return spec, "", false
	}
	spec.Minute, spec.Hour, spec.DayMonth, spec.Month, spec.DayWeek = timeFields[0], timeFields[1], timeFields[2], timeFields[3], timeFields[4]
	if withUser {
		u, cmd, ok := splitCronFields(tail, 1)
		if !ok {
			return spec, "", false
		}
		spec.Command = cmd
		return spec, u[0], true
	}
	spec.Command = tail
	return spec, "", true
}

// cronFieldValid accepts *, */n, n, n-m, n/m, lists thereof and month/dow names.
func cronFieldValid(field string, idx int) bool {
	field = strings.TrimSpace(field)
	if field == "" || field == "*" {
		return field != ""
	}
	for _, part := range strings.Split(field, ",") {
		part = strings.TrimSpace(strings.ToLower(part))
		if part == "" {
			return false
		}
		step := ""
		if i := strings.Index(part, "/"); i >= 0 {
			step = part[i+1:]
			part = part[:i]
			if !cronNumRe.MatchString(step) {
				return false
			}
			if n, _ := strconv.Atoi(step); n < 1 || n > cronBounds[idx][1] {
				return false
			}
		}
		if part == "" || part == "*" {
			if part == "" && step == "" {
				return false
			}
			continue
		}
		lo, hi := part, part
		if i := strings.Index(part, "-"); i >= 0 {
			lo, hi = part[:i], part[i+1:]
		}
		for _, v := range []string{lo, hi} {
			if cronNameRe[idx][v] {
				continue
			}
			if !cronNumRe.MatchString(v) {
				return false
			}
			n, _ := strconv.Atoi(v)
			if n < cronBounds[idx][0] || n > cronBounds[idx][1] {
				return false
			}
		}
	}
	return true
}

func validateCronSpec(spec shared.CronEntrySpec) error {
	fields := []struct {
		name string
		val  string
		idx  int
	}{
		{"minute", spec.Minute, 0},
		{"hour", spec.Hour, 1},
		{"day of month", spec.DayMonth, 2},
		{"month", spec.Month, 3},
		{"day of week", spec.DayWeek, 4},
	}
	for _, f := range fields {
		if !cronFieldValid(f.val, f.idx) {
			return fmt.Errorf("bad %s field %q", f.name, f.val)
		}
	}
	if strings.TrimSpace(spec.Command) == "" {
		return fmt.Errorf("command is empty")
	}
	if strings.Contains(spec.Command, "\n") {
		return fmt.Errorf("command must be a single line")
	}
	return nil
}

func renderCronSpec(spec shared.CronEntrySpec) string {
	return strings.Join([]string{
		strings.TrimSpace(spec.Minute),
		strings.TrimSpace(spec.Hour),
		strings.TrimSpace(spec.DayMonth),
		strings.TrimSpace(spec.Month),
		strings.TrimSpace(spec.DayWeek),
		strings.TrimSpace(spec.Command),
	}, " ")
}

// crontabEntryLines returns the line indexes holding real entries, so edits
// keep comments, blank lines and env assignments untouched.
func crontabEntryLines(lines []string) []int {
	var idx []int
	for i, l := range lines {
		if _, _, ok := parseCronLine(l, false); ok {
			idx = append(idx, i)
		}
	}
	return idx
}

func cronID(n int) string { return "crontab:" + strconv.Itoa(n) }

func parseCronID(id string) (int, bool) {
	n, err := strconv.Atoi(strings.TrimPrefix(id, "crontab:"))
	if id == "" || err != nil || n < 0 || !strings.HasPrefix(id, "crontab:") {
		return 0, false
	}
	return n, true
}

func (c *linuxCollector) CronState() (shared.CronState, error) {
	st := shared.CronState{CronAvailable: cronAvailable()}
	if st.CronAvailable {
		lines, err := loadCrontab()
		if err != nil {
			return st, err
		}
		n := 0
		for _, l := range lines {
			spec, _, ok := parseCronLine(l, false)
			if !ok {
				continue
			}
			st.Entries = append(st.Entries, shared.CronEntry{
				ID: cronID(n), Source: "crontab",
				Minute: spec.Minute, Hour: spec.Hour, DayMonth: spec.DayMonth,
				Month: spec.Month, DayWeek: spec.DayWeek,
				Command: spec.Command, Editable: spec.Minute != "@reboot",
			})
			n++
		}
	}
	st.Entries = append(st.Entries, readSystemCronFiles()...)
	st.Timers = listSystemdTimers()
	return st, nil
}

func readSystemCronFiles() []shared.CronEntry {
	var out []shared.CronEntry
	files := []string{"/etc/crontab"}
	matches, _ := filepath.Glob("/etc/cron.d/*")
	files = append(files, matches...)
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		info, err := os.Stat(f)
		if err != nil || info.IsDir() {
			continue
		}
		src := f
		if strings.HasPrefix(f, "/etc/cron.d/") {
			src = "cron.d/" + filepath.Base(f)
		} else if f == "/etc/crontab" {
			src = "crontab-system"
		}
		for _, l := range strings.Split(string(raw), "\n") {
			spec, user, ok := parseCronLine(l, true)
			if !ok {
				continue
			}
			out = append(out, shared.CronEntry{
				Source: src,
				Minute: spec.Minute, Hour: spec.Hour, DayMonth: spec.DayMonth,
				Month: spec.Month, DayWeek: spec.DayWeek,
				User: user, Command: spec.Command,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Source != out[j].Source {
			return out[i].Source < out[j].Source
		}
		return out[i].Command < out[j].Command
	})
	return out
}

type systemdTimerJSON struct {
	Unit    string `json:"unit"`
	Active  string `json:"active"`
	Next    string `json:"next"`
	Last    string `json:"last"`
}

func listSystemdTimers() []shared.SystemdTimer {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return nil
	}
	out, err := runCmd(10*time.Second, "systemctl", "list-timers", "--all", "--no-legend", "--no-pager", "--output=json")
	if err != nil {
		return nil
	}
	var rows []systemdTimerJSON
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		return nil
	}
	var out2 []shared.SystemdTimer
	for _, r := range rows {
		out2 = append(out2, shared.SystemdTimer{
			Unit: r.Unit, Active: r.Active, Next: r.Next, Last: r.Last,
		})
	}
	return out2
}

func (c *linuxCollector) CronCreate(spec shared.CronEntrySpec) (shared.CronEntry, error) {
	var zero shared.CronEntry
	if err := validateCronSpec(spec); err != nil {
		return zero, err
	}
	if !cronAvailable() {
		return zero, fmt.Errorf("crontab not found")
	}
	cronMu.Lock()
	defer cronMu.Unlock()
	lines, err := loadCrontab()
	if err != nil {
		return zero, err
	}
	lines = append(lines, renderCronSpec(spec))
	if err := saveCrontab(lines); err != nil {
		return zero, err
	}
	n := len(crontabEntryLines(lines)) - 1
	return shared.CronEntry{
		ID: cronID(n), Source: "crontab",
		Minute: spec.Minute, Hour: spec.Hour, DayMonth: spec.DayMonth,
		Month: spec.Month, DayWeek: spec.DayWeek,
		Command: spec.Command, Editable: true,
	}, nil
}

func (c *linuxCollector) CronUpdate(id string, spec shared.CronEntrySpec) error {
	if err := validateCronSpec(spec); err != nil {
		return err
	}
	n, ok := parseCronID(id)
	if !ok {
		return fmt.Errorf("unknown entry %q", id)
	}
	if !cronAvailable() {
		return fmt.Errorf("crontab not found")
	}
	cronMu.Lock()
	defer cronMu.Unlock()
	lines, err := loadCrontab()
	if err != nil {
		return err
	}
	entryLines := crontabEntryLines(lines)
	if n >= len(entryLines) {
		return fmt.Errorf("entry %q no longer exists — reload and retry", id)
	}
	old, _, _ := parseCronLine(lines[entryLines[n]], false)
	if old.Minute == "@reboot" {
		return fmt.Errorf("@reboot entries cannot be edited here")
	}
	lines[entryLines[n]] = renderCronSpec(spec)
	return saveCrontab(lines)
}

func (c *linuxCollector) CronDelete(id string) error {
	n, ok := parseCronID(id)
	if !ok {
		return fmt.Errorf("unknown entry %q", id)
	}
	if !cronAvailable() {
		return fmt.Errorf("crontab not found")
	}
	cronMu.Lock()
	defer cronMu.Unlock()
	lines, err := loadCrontab()
	if err != nil {
		return err
	}
	entryLines := crontabEntryLines(lines)
	if n >= len(entryLines) {
		return fmt.Errorf("entry %q no longer exists — reload and retry", id)
	}
	lines = append(lines[:entryLines[n]], lines[entryLines[n]+1:]...)
	return saveCrontab(lines)
}
