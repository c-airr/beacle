package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"beacle/shared"
)

// What each server was running when a metric jumped.
//
// The chart answers "when", and until now nothing answered "what". Coming back
// in the morning to a CPU wall at four a.m. left no way to find out the cause,
// because a process list only ever describes the present. Agents now write one
// down at the moment a metric departs from that machine's own baseline, and
// hand it over on connect; this is where it lands.
//
// Stored per server alongside history and for the same fortnight — a record
// whose chart has been trimmed away has nothing left to attach to.
type Spikes struct {
	mu  sync.Mutex
	dir string

	// byVPS[id] is ordered oldest first. Held in memory because the panel asks
	// for them by time window on every chart click, and a fortnight of
	// incidents for one server is a few hundred records at most.
	byVPS map[string][]shared.SpikeRecord
}

const (
	spikeRetain = 14 * 24 * time.Hour
	// Generous: this is a cap against a misbehaving agent, not a budget. A
	// machine with more incidents than this a fortnight has a bigger problem
	// than storage.
	maxSpikesPerVPS = 5000
)

func NewSpikes(dataDir string) *Spikes {
	s := &Spikes{
		dir:   filepath.Join(dataDir, "spikes"),
		byVPS: map[string][]shared.SpikeRecord{},
	}
	_ = os.MkdirAll(s.dir, 0o755)
	s.load()
	return s
}

func (s *Spikes) pathFor(vpsID string) string {
	return filepath.Join(s.dir, vpsID+".jsonl")
}

func (s *Spikes) load() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-spikeRetain)
	for _, e := range entries {
		name := e.Name()
		if filepath.Ext(name) != ".jsonl" {
			continue
		}
		vpsID := name[:len(name)-len(".jsonl")]
		f, err := os.Open(filepath.Join(s.dir, name))
		if err != nil {
			continue
		}
		var out []shared.SpikeRecord
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 8192), 256*1024)
		for sc.Scan() {
			var r shared.SpikeRecord
			if json.Unmarshal(sc.Bytes(), &r) != nil {
				continue
			}
			if r.At.IsZero() || r.At.Before(cutoff) {
				continue
			}
			out = append(out, r)
		}
		f.Close()
		if len(out) == 0 {
			continue
		}
		sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
		s.byVPS[vpsID] = out
	}
}

// Record stores spikes handed over by an agent. Returns how many were new.
//
// Agents re-send a batch they could not confirm was delivered — losing an
// incident is worse than receiving it twice — so duplicates arrive by design
// and are dropped here, matched on metric and minute.
func (s *Spikes) Record(vpsID string, records []shared.SpikeRecord) int {
	if len(records) == 0 {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-spikeRetain)
	horizon := time.Now().Add(time.Hour)
	existing := s.byVPS[vpsID]

	type key struct {
		metric string
		minute int64
	}
	seen := make(map[key]struct{}, len(existing))
	for _, r := range existing {
		seen[key{r.Metric, r.At.Unix() / 60}] = struct{}{}
	}

	added := 0
	for _, r := range records {
		if r.At.IsZero() || r.At.Before(cutoff) {
			continue
		}
		// A clock set forward would otherwise park records in the future,
		// where they sit beyond every chart window and never appear.
		if r.At.After(horizon) {
			continue
		}
		k := key{r.Metric, r.At.Unix() / 60}
		if _, dup := seen[k]; dup {
			continue
		}
		seen[k] = struct{}{}
		existing = append(existing, r)
		added++
	}
	if added == 0 {
		return 0
	}

	sort.Slice(existing, func(i, j int) bool { return existing[i].At.Before(existing[j].At) })
	if len(existing) > maxSpikesPerVPS {
		existing = existing[len(existing)-maxSpikesPerVPS:]
	}
	s.byVPS[vpsID] = existing
	s.rewriteLocked(vpsID, existing)
	return added
}

// Query returns spikes inside a window, oldest first. A zero bound means no
// bound on that side.
func (s *Spikes) Query(vpsID string, from, to time.Time) []shared.SpikeRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	all := s.byVPS[vpsID]
	out := make([]shared.SpikeRecord, 0, len(all))
	for _, r := range all {
		if !from.IsZero() && r.At.Before(from) {
			continue
		}
		if !to.IsZero() && r.At.After(to) {
			continue
		}
		out = append(out, r)
	}
	return out
}

// Nearest returns the spike closest to a moment, within tolerance. This is what
// a click on the chart resolves to: the reader points at a peak, not at a
// timestamp, and the record a minute either side is the one they mean.
func (s *Spikes) Nearest(vpsID string, at time.Time, tolerance time.Duration) *shared.SpikeRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	var best *shared.SpikeRecord
	var bestGap time.Duration
	for i := range s.byVPS[vpsID] {
		r := &s.byVPS[vpsID][i]
		gap := r.At.Sub(at)
		if gap < 0 {
			gap = -gap
		}
		if gap > tolerance {
			continue
		}
		if best == nil || gap < bestGap {
			best, bestGap = r, gap
		}
	}
	if best == nil {
		return nil
	}
	cp := *best
	return &cp
}

// Forget removes a deleted server's records.
func (s *Spikes) Forget(vpsID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.byVPS, vpsID)
	_ = os.Remove(s.pathFor(vpsID))
}

// RunTrim keeps the files bounded for as long as the backend runs.
func (s *Spikes) RunTrim() {
	for range time.Tick(time.Hour) {
		s.Trim()
	}
}

// Trim drops records past retention. Called on the same slow timer as history.
func (s *Spikes) Trim() {
	cutoff := time.Now().Add(-spikeRetain)
	s.mu.Lock()
	defer s.mu.Unlock()
	for vpsID, all := range s.byVPS {
		keep := all[:0]
		for _, r := range all {
			if r.At.After(cutoff) {
				keep = append(keep, r)
			}
		}
		if len(keep) == len(all) {
			continue
		}
		s.byVPS[vpsID] = keep
		s.rewriteLocked(vpsID, keep)
	}
}

func (s *Spikes) rewriteLocked(vpsID string, records []shared.SpikeRecord) {
	tmp := s.pathFor(vpsID) + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	for _, r := range records {
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
	os.Rename(tmp, s.pathFor(vpsID))
}
