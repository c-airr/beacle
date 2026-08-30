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

// Samples recorded while the panel is unreachable.
//
// History lives on the desktop: the backend writes a sample a minute as
// snapshots arrive. That means it only records while the panel is running, so
// closing the laptop drew an outage across the whole fleet — you came back in
// the morning to a wall of red for servers that had been up all night. The gap
// was real data loss, not a display bug, so it had to be fixed where the data
// is produced.
//
// While disconnected the agent samples itself and appends here. On reconnect
// the file is handed over and only then deleted, so a drop mid-handover costs
// nothing: the samples are still on disk and go again next time. Duplicates are
// cheaper than holes — the backend already keeps one sample per minute and
// drops the rest.
type OfflineBuffer struct {
	mu   sync.Mutex
	path string

	// Bounded so a machine that never sees its panel again cannot fill a disk
	// it does not own. At a sample a minute this is a fortnight, matching what
	// the backend keeps; past that the oldest go first.
	max int
}

const (
	offlineSampleInterval = time.Minute
	offlineMaxSamples     = 14 * 24 * 60

	// Sent in chunks: a fortnight of samples is a megabyte of JSON, and the
	// write buffer holds 64 messages. One giant frame would also be dropped by
	// any proxy with a frame limit in between.
	offlineChunkSize = 500
)

func NewOfflineBuffer(dir string) *OfflineBuffer {
	_ = os.MkdirAll(dir, 0o700)
	return &OfflineBuffer{
		path: filepath.Join(dir, "offline-samples.jsonl"),
		max:  offlineMaxSamples,
	}
}

// Append records one sample. Appending rather than rewriting keeps the cost
// flat and means a power cut loses at most the line being written.
func (b *OfflineBuffer) Append(s shared.MetricSample) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	line, err := json.Marshal(s)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(b.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return b.trimLocked()
}

// Load returns every buffered sample, oldest first.
func (b *OfflineBuffer) Load() ([]shared.MetricSample, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.loadLocked()
}

func (b *OfflineBuffer) loadLocked() ([]shared.MetricSample, error) {
	f, err := os.Open(b.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	var out []shared.MetricSample
	sc := bufio.NewScanner(f)
	// A sample is a few hundred bytes; cap the buffer so a corrupted file
	// cannot hand us something enormous.
	sc.Buffer(make([]byte, 0, 4096), 64*1024)
	for sc.Scan() {
		var s shared.MetricSample
		if json.Unmarshal(sc.Bytes(), &s) != nil {
			// A torn last line after a power cut is not worth failing over —
			// the rest of the file is still good.
			continue
		}
		if s.At.IsZero() {
			continue
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// DropUpTo removes samples at or before cutoff, keeping anything newer. Called
// only once the backend has the samples, so a handover that dies part-way
// leaves the rest on disk to send again.
func (b *OfflineBuffer) DropUpTo(cutoff time.Time) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	all, err := b.loadLocked()
	if err != nil {
		return err
	}
	keep := make([]shared.MetricSample, 0, len(all))
	for _, s := range all {
		if s.At.After(cutoff) {
			keep = append(keep, s)
		}
	}
	if len(keep) == 0 {
		return b.removeLocked()
	}
	return b.rewriteLocked(keep)
}

// Clear drops everything.
func (b *OfflineBuffer) Clear() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.removeLocked()
}

func (b *OfflineBuffer) removeLocked() error {
	err := os.Remove(b.path)
	if err != nil && os.IsNotExist(err) {
		return nil
	}
	return err
}

func (b *OfflineBuffer) trimLocked() error {
	all, err := b.loadLocked()
	if err != nil || len(all) <= b.max {
		return err
	}
	return b.rewriteLocked(all[len(all)-b.max:])
}

// rewriteLocked replaces the file atomically, so an interrupted trim cannot
// leave a half-written buffer where a whole one used to be.
func (b *OfflineBuffer) rewriteLocked(samples []shared.MetricSample) error {
	tmp := b.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, s := range samples {
		line, err := json.Marshal(s)
		if err != nil {
			continue
		}
		if _, err := w.Write(append(line, '\n')); err != nil {
			f.Close()
			os.Remove(tmp)
			return err
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, b.path)
}

// chunk splits samples for sending. Returns nil for an empty input so the
// caller sends nothing rather than an empty frame.
func chunkSamples(all []shared.MetricSample, size int) [][]shared.MetricSample {
	if len(all) == 0 {
		return nil
	}
	if size <= 0 {
		size = offlineChunkSize
	}
	var out [][]shared.MetricSample
	for i := 0; i < len(all); i += size {
		end := i + size
		if end > len(all) {
			end = len(all)
		}
		out = append(out, all[i:end])
	}
	return out
}
