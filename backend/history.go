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

// History records one metric sample per VPS per minute and keeps it for weeks,
// so the panel can answer questions asked after the fact: was the box thrashing
// at four in the morning, did it drop off the network while nobody was looking,
// when did the memory actually start climbing.
//
// Kept apart from state.json deliberately. That file is the VPS registry and
// its tokens, rewritten on every structural change; appending a sample per
// server per minute to it would mean rewriting the registry thousands of times
// a day. Each server gets its own append-only file instead, which is cheap to
// write and trivial to trim.
type History struct {
	mu  sync.Mutex
	dir string

	// samples[vpsID] is ordered oldest first. Loaded once at startup and kept
	// in memory: a week per server is a few thousand small structs, far less
	// than one Docker snapshot.
	samples map[string][]shared.MetricSample
	lastAt  map[string]time.Time
}

const (
	// One sample a minute is enough to see a spike that lasted a few minutes
	// and cheap enough to keep for a long time.
	historyInterval = time.Minute
	historyRetain   = 14 * 24 * time.Hour
	// Guards against a burst of frames writing a burst of samples if the clock
	// jumps or a snapshot arrives out of order.
	maxSamplesPerVPS = 30 * 24 * 60
)

func NewHistory(dataDir string) *History {
	h := &History{
		dir:     filepath.Join(dataDir, "history"),
		samples: map[string][]shared.MetricSample{},
		lastAt:  map[string]time.Time{},
	}
	_ = os.MkdirAll(h.dir, 0o755)
	h.load()
	return h
}

func (h *History) pathFor(vpsID string) string {
	return filepath.Join(h.dir, vpsID+".jsonl")
}

// load reads every server's file at startup, dropping anything past retention
// as it goes.
func (h *History) load() {
	entries, err := os.ReadDir(h.dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-historyRetain)
	for _, e := range entries {
		name := e.Name()
		if filepath.Ext(name) != ".jsonl" {
			continue
		}
		vpsID := name[:len(name)-len(".jsonl")]
		f, err := os.Open(filepath.Join(h.dir, name))
		if err != nil {
			continue
		}
		var out []shared.MetricSample
		sc := bufio.NewScanner(f)
		// A long history line is still tiny, but a corrupted file could hand us
		// something enormous; cap the buffer rather than trusting the contents.
		sc.Buffer(make([]byte, 0, 4096), 64*1024)
		for sc.Scan() {
			var s shared.MetricSample
			if json.Unmarshal(sc.Bytes(), &s) != nil {
				continue // a torn last line after a crash is not worth failing over
			}
			if s.At.Before(cutoff) {
				continue
			}
			out = append(out, s)
		}
		f.Close()
		if len(out) == 0 {
			continue
		}
		sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
		h.samples[vpsID] = out
		h.lastAt[vpsID] = out[len(out)-1].At
	}
}

// Record stores a sample, at most one per interval per server. Returns whether
// anything was written, which the caller uses to avoid pointless disk work.
func (h *History) Record(vpsID string, s shared.MetricSample) bool {
	h.mu.Lock()
	defer h.mu.Unlock()

	if last, ok := h.lastAt[vpsID]; ok && s.At.Sub(last) < historyInterval {
		return false
	}
	h.lastAt[vpsID] = s.At
	h.samples[vpsID] = append(h.samples[vpsID], s)

	if len(h.samples[vpsID]) > maxSamplesPerVPS {
		h.samples[vpsID] = h.samples[vpsID][len(h.samples[vpsID])-maxSamplesPerVPS:]
	}

	line, err := json.Marshal(s)
	if err != nil {
		return false
	}
	f, err := os.OpenFile(h.pathFor(vpsID), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return false
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
	return true
}

// Query returns the samples inside a window, oldest first. A zero from or to
// means "no bound on that side".
func (h *History) Query(vpsID string, from, to time.Time) []shared.MetricSample {
	h.mu.Lock()
	defer h.mu.Unlock()

	all := h.samples[vpsID]
	out := make([]shared.MetricSample, 0, len(all))
	for _, s := range all {
		if !from.IsZero() && s.At.Before(from) {
			continue
		}
		if !to.IsZero() && s.At.After(to) {
			continue
		}
		out = append(out, s)
	}
	return out
}

// Span reports the oldest and newest sample held for a server, so the panel can
// bound its date picker to what actually exists instead of offering a week of
// empty chart.
func (h *History) Span(vpsID string) (first, last time.Time) {
	h.mu.Lock()
	defer h.mu.Unlock()
	all := h.samples[vpsID]
	if len(all) == 0 {
		return time.Time{}, time.Time{}
	}
	return all[0].At, all[len(all)-1].At
}

// Trim drops samples past retention and rewrites the files. Called on a slow
// timer — the in-memory cap keeps things bounded between runs.
func (h *History) Trim() {
	cutoff := time.Now().Add(-historyRetain)

	h.mu.Lock()
	defer h.mu.Unlock()
	for vpsID, all := range h.samples {
		keep := all[:0]
		for _, s := range all {
			if s.At.After(cutoff) {
				keep = append(keep, s)
			}
		}
		if len(keep) == len(all) {
			continue
		}
		h.samples[vpsID] = keep
		h.rewriteLocked(vpsID, keep)
	}
}

// Forget removes a deleted server's history rather than leaving a file nobody
// will ever look at again.
func (h *History) Forget(vpsID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.samples, vpsID)
	delete(h.lastAt, vpsID)
	_ = os.Remove(h.pathFor(vpsID))
}

func (h *History) rewriteLocked(vpsID string, samples []shared.MetricSample) {
	tmp := h.pathFor(vpsID) + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return
	}
	w := bufio.NewWriter(f)
	for _, s := range samples {
		line, err := json.Marshal(s)
		if err != nil {
			continue
		}
		_, _ = w.Write(append(line, '\n'))
	}
	_ = w.Flush()
	_ = f.Close()
	// Rename over the original so a crash mid-write leaves the old file intact
	// rather than a half-written one.
	_ = os.Rename(tmp, h.pathFor(vpsID))
}

// RunTrim keeps the files bounded for as long as the backend runs.
func (h *History) RunTrim() {
	for range time.Tick(time.Hour) {
		h.Trim()
	}
}

// SampleFrom turns a live snapshot into the handful of numbers worth keeping.
func SampleFrom(snap *shared.VPSSnapshot) shared.MetricSample {
	m := snap.Metrics

	// The busiest disk is the one worth charting: a full root partition is a
	// problem whatever the others are doing.
	worstDisk := 0.0
	for _, d := range m.Disks {
		if d.UsedPercent > worstDisk {
			worstDisk = d.UsedPercent
		}
	}

	// Interfaces are summed rather than picked from, because which one carries
	// the traffic differs per host and a chart of the wrong one is worse than
	// no chart.
	var rx, tx uint64
	for _, n := range m.Network {
		rx += n.RxPerSec
		tx += n.TxPerSec
	}

	at := m.CollectedAt
	if at.IsZero() {
		at = time.Now()
	}
	return shared.MetricSample{
		At:     at.UTC(),
		CPU:    m.CPUPercent,
		Mem:    m.MemPercent,
		Disk:   worstDisk,
		RxPerS: rx,
		TxPerS: tx,
		Load1:  m.Load1,
	}
}
