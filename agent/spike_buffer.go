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

// Spike records waiting to be handed to the panel.
//
// Same shape and the same reasoning as OfflineBuffer: written on the VPS,
// deleted only once delivered, capped so a machine nobody is watching cannot
// fill a disk it does not own. Kept in its own file because the two have
// different lifetimes — samples are dropped as soon as the panel has them,
// while these are worth keeping around long enough to be looked at twice.
type SpikeBuffer struct {
	mu   sync.Mutex
	path string
	max  int
}

const (
	// A fortnight of incidents, matching how long the backend keeps history:
	// a spike whose chart has been trimmed away has nothing left to attach to.
	spikeRetain = 14 * 24 * time.Hour
	// A busy machine might have a few dozen a day. This is generous enough
	// that the cap is never the reason something is missing, and small enough
	// to stay a rounding error on disk.
	spikeMaxRecords = 2000
	// How many processes are kept per incident. Enough to see a culprit and
	// what it was competing with; not an inventory.
	spikeTopN = 8
	// Sent in one frame per batch on reconnect.
	spikeChunkSize = 50
)

func NewSpikeBuffer(dir string) *SpikeBuffer {
	_ = os.MkdirAll(dir, 0o700)
	return &SpikeBuffer{
		path: filepath.Join(dir, "spikes.jsonl"),
		max:  spikeMaxRecords,
	}
}

func (b *SpikeBuffer) Append(r shared.SpikeRecord) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	line, err := json.Marshal(r)
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

func (b *SpikeBuffer) Load() ([]shared.SpikeRecord, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.loadLocked()
}

func (b *SpikeBuffer) loadLocked() ([]shared.SpikeRecord, error) {
	f, err := os.Open(b.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	cutoff := time.Now().Add(-spikeRetain)
	var out []shared.SpikeRecord
	sc := bufio.NewScanner(f)
	// A record with eight processes and their command lines is a few KB; the
	// cap stops a corrupted file handing back something enormous.
	sc.Buffer(make([]byte, 0, 8192), 256*1024)
	for sc.Scan() {
		var r shared.SpikeRecord
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue // a torn last line after a power cut
		}
		if r.At.IsZero() || r.At.Before(cutoff) {
			continue
		}
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.Before(out[j].At) })
	return out, nil
}

// DropUpTo removes records at or before cutoff. Called only once the backend
// has them, so an interrupted handover leaves the rest to send again.
func (b *SpikeBuffer) DropUpTo(cutoff time.Time) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	all, err := b.loadLocked()
	if err != nil {
		return err
	}
	keep := make([]shared.SpikeRecord, 0, len(all))
	for _, r := range all {
		if r.At.After(cutoff) {
			keep = append(keep, r)
		}
	}
	if len(keep) == 0 {
		err := os.Remove(b.path)
		if err != nil && os.IsNotExist(err) {
			return nil
		}
		return err
	}
	return b.rewriteLocked(keep)
}

func (b *SpikeBuffer) trimLocked() error {
	all, err := b.loadLocked()
	if err != nil || len(all) <= b.max {
		return err
	}
	return b.rewriteLocked(all[len(all)-b.max:])
}

func (b *SpikeBuffer) rewriteLocked(records []shared.SpikeRecord) error {
	tmp := b.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, r := range records {
		line, err := json.Marshal(r)
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

func chunkSpikes(all []shared.SpikeRecord, size int) [][]shared.SpikeRecord {
	if len(all) == 0 {
		return nil
	}
	if size <= 0 {
		size = spikeChunkSize
	}
	var out [][]shared.SpikeRecord
	for i := 0; i < len(all); i += size {
		end := i + size
		if end > len(all) {
			end = len(all)
		}
		out = append(out, all[i:end])
	}
	return out
}

// topProcesses picks the processes worth keeping for a spike, ranked by
// whichever metric jumped — a memory spike explained by a CPU ranking would
// name the wrong process.
func topProcesses(procs []shared.ProcessInfo, metric string, n int) []shared.SpikeProcess {
	ranked := append([]shared.ProcessInfo(nil), procs...)
	sort.Slice(ranked, func(i, j int) bool {
		if metric == "mem" {
			return ranked[i].MemPercent > ranked[j].MemPercent
		}
		return ranked[i].CPUPercent > ranked[j].CPUPercent
	})
	if len(ranked) > n {
		ranked = ranked[:n]
	}
	out := make([]shared.SpikeProcess, 0, len(ranked))
	for _, p := range ranked {
		cmd := p.Command
		// The full command line of a java service is a screenful. Enough to
		// identify it is enough; the live process table has the rest.
		if len(cmd) > 200 {
			cmd = cmd[:200] + "…"
		}
		out = append(out, shared.SpikeProcess{
			PID:        p.PID,
			Name:       p.Name,
			User:       p.User,
			CPUPercent: p.CPUPercent,
			MemPercent: p.MemPercent,
			Command:    cmd,
		})
	}
	return out
}
