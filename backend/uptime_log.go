package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// A record of when the panel itself was running.
//
// History is only written while the backend is up, so closing the laptop
// leaves the same shape in the data as a server going down: a stretch with no
// samples. The chart drew both in red as an outage, which meant a fortnight of
// perfectly healthy nights looked like a fleet that kept falling over.
//
// The two are only distinguishable if something remembers when the panel was
// there. That is this: a heartbeat written once a minute, so a gap in it is a
// period nobody was recording. It cannot be derived after the fact, which is
// why it is worth a file of its own.
//
// Agents buffer their own samples now and hand them over on reconnect, so
// gaps of this kind stop appearing going forward. The record still matters for
// history already on disk, and for stretches no agent could cover — one that
// was itself offline, or installed after the fact.
type UptimeLog struct {
	mu   sync.Mutex
	path string

	// Current run, extended by each heartbeat rather than appended, so a run
	// costs two numbers however long it lasts.
	current uptimeRun
	runs    []uptimeRun
}

type uptimeRun struct {
	From time.Time `json:"from"`
	To   time.Time `json:"to"`
}

const (
	// Often enough to place a gap to the minute, matching the sample interval.
	uptimeHeartbeat = time.Minute
	// Two heartbeats: a single missed tick under load is not a shutdown.
	uptimeGapAfter = 3 * time.Minute
	uptimeRetain   = 14 * 24 * time.Hour
)

func NewUptimeLog(dataDir string) *UptimeLog {
	u := &UptimeLog{path: filepath.Join(dataDir, "uptime.jsonl")}
	u.load()
	now := time.Now().UTC()
	u.current = uptimeRun{From: now, To: now}
	return u
}

func (u *UptimeLog) load() {
	f, err := os.Open(u.path)
	if err != nil {
		return
	}
	defer f.Close()

	cutoff := time.Now().Add(-uptimeRetain)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 4096), 64*1024)
	for sc.Scan() {
		var r uptimeRun
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue // a torn last line after a power cut
		}
		if r.To.Before(cutoff) || r.To.Before(r.From) {
			continue
		}
		u.runs = append(u.runs, r)
	}
	sort.Slice(u.runs, func(i, j int) bool { return u.runs[i].From.Before(u.runs[j].From) })
}

// Run extends the current run for as long as the backend is up.
func (u *UptimeLog) Run() {
	u.persist()
	for range time.Tick(uptimeHeartbeat) {
		u.mu.Lock()
		u.current.To = time.Now().UTC()
		u.mu.Unlock()
		u.persist()
	}
}

// persist rewrites the whole file. It holds one line per run — a fortnight of
// daily use is a dozen or so — so rewriting is cheaper than tracking an offset
// to overwrite, and leaves nothing half-written after a crash.
func (u *UptimeLog) persist() {
	u.mu.Lock()
	all := append(append([]uptimeRun{}, u.runs...), u.current)
	path := u.path
	u.mu.Unlock()

	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	for _, r := range all {
		line, err := json.Marshal(r)
		if err != nil {
			continue
		}
		w.Write(append(line, '\n'))
	}
	if w.Flush() != nil || f.Close() != nil {
		os.Remove(tmp)
		return
	}
	os.Rename(tmp, path)
}

// DownFrom reports the stretches the panel was NOT running, inside a window.
// These are the gaps a chart should explain rather than blame on a server.
func (u *UptimeLog) DownFrom(from, to time.Time) []uptimeRun {
	u.mu.Lock()
	all := append(append([]uptimeRun{}, u.runs...), u.current)
	u.mu.Unlock()

	sort.Slice(all, func(i, j int) bool { return all[i].From.Before(all[j].From) })

	// Merge runs that touch, so a restart does not read as downtime.
	merged := make([]uptimeRun, 0, len(all))
	for _, r := range all {
		if n := len(merged); n > 0 && r.From.Sub(merged[n-1].To) <= uptimeGapAfter {
			if r.To.After(merged[n-1].To) {
				merged[n-1].To = r.To
			}
			continue
		}
		merged = append(merged, r)
	}

	var down []uptimeRun
	cursor := from
	for _, r := range merged {
		if r.To.Before(from) {
			continue
		}
		if r.From.After(to) {
			break
		}
		if r.From.After(cursor) && r.From.Sub(cursor) > uptimeGapAfter {
			down = append(down, uptimeRun{From: cursor, To: r.From})
		}
		if r.To.After(cursor) {
			cursor = r.To
		}
	}
	if to.Sub(cursor) > uptimeGapAfter {
		down = append(down, uptimeRun{From: cursor, To: to})
	}
	return down
}
