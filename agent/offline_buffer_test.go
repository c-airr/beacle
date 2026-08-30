package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
)

func sampleAt(min int) shared.MetricSample {
	base := time.Date(2026, 8, 30, 2, 0, 0, 0, time.UTC)
	return shared.MetricSample{At: base.Add(time.Duration(min) * time.Minute), CPU: float64(min)}
}

func TestBufferRoundTripsSamplesInOrder(t *testing.T) {
	b := NewOfflineBuffer(t.TempDir())
	for _, m := range []int{2, 0, 1} { // deliberately out of order
		if err := b.Append(sampleAt(m)); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	got, err := b.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("want 3 samples, got %d", len(got))
	}
	for i := 1; i < len(got); i++ {
		if !got[i].At.After(got[i-1].At) {
			t.Fatalf("samples are not oldest-first: %v then %v", got[i-1].At, got[i].At)
		}
	}
}

func TestSamplesSurviveUntilTheyAreAcknowledged(t *testing.T) {
	// The whole point of the design: a handover that dies part-way must not
	// cost the samples it did not deliver.
	b := NewOfflineBuffer(t.TempDir())
	for m := 0; m < 5; m++ {
		if err := b.Append(sampleAt(m)); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	// Backend confirmed the first three only.
	if err := b.DropUpTo(sampleAt(2).At); err != nil {
		t.Fatalf("drop: %v", err)
	}
	left, err := b.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(left) != 2 {
		t.Fatalf("want the 2 unacknowledged samples, got %d", len(left))
	}
	if !left[0].At.Equal(sampleAt(3).At) {
		t.Fatalf("wrong sample survived: %v", left[0].At)
	}
}

func TestDroppingEverythingRemovesTheFile(t *testing.T) {
	dir := t.TempDir()
	b := NewOfflineBuffer(dir)
	if err := b.Append(sampleAt(0)); err != nil {
		t.Fatalf("append: %v", err)
	}
	if err := b.DropUpTo(sampleAt(0).At); err != nil {
		t.Fatalf("drop: %v", err)
	}
	// A reconnected agent should leave nothing behind on the VPS.
	if _, err := os.Stat(filepath.Join(dir, "offline-samples.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("buffer file still present after full drop")
	}
	got, err := b.Load()
	if err != nil || len(got) != 0 {
		t.Fatalf("want empty buffer, got %d samples (err %v)", len(got), err)
	}
}

func TestBufferIsBoundedSoItCannotFillTheDisk(t *testing.T) {
	b := NewOfflineBuffer(t.TempDir())
	b.max = 10
	for m := 0; m < 25; m++ {
		if err := b.Append(sampleAt(m)); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	got, err := b.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(got) != 10 {
		t.Fatalf("want the cap of 10, got %d", len(got))
	}
	// The oldest go first: what is left must be the most recent window.
	if !got[len(got)-1].At.Equal(sampleAt(24).At) {
		t.Fatalf("newest sample was discarded: %v", got[len(got)-1].At)
	}
	if !got[0].At.Equal(sampleAt(15).At) {
		t.Fatalf("wrong window kept, starts at %v", got[0].At)
	}
}

func TestATornLineDoesNotLoseTheRestOfTheFile(t *testing.T) {
	// A power cut can leave half a line behind. Losing a fortnight of history
	// over one bad byte would be worse than skipping it.
	dir := t.TempDir()
	b := NewOfflineBuffer(dir)
	if err := b.Append(sampleAt(0)); err != nil {
		t.Fatalf("append: %v", err)
	}
	path := filepath.Join(dir, "offline-samples.jsonl")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	f.WriteString("{\"at\":\"2026-08-30T02:0")
	f.Close()

	got, err := b.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want the one intact sample, got %d", len(got))
	}
}

func TestLoadingAnAbsentBufferIsNotAnError(t *testing.T) {
	// The normal case: the panel has never been away.
	b := NewOfflineBuffer(t.TempDir())
	got, err := b.Load()
	if err != nil {
		t.Fatalf("want no error for a missing buffer, got %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("want no samples, got %d", len(got))
	}
}

func TestSamplesAreSentInChunks(t *testing.T) {
	all := make([]shared.MetricSample, 0, 1200)
	for m := 0; m < 1200; m++ {
		all = append(all, sampleAt(m))
	}
	chunks := chunkSamples(all, 500)
	if len(chunks) != 3 {
		t.Fatalf("want 3 chunks, got %d", len(chunks))
	}
	total := 0
	for _, c := range chunks {
		if len(c) > 500 {
			t.Fatalf("chunk too big: %d", len(c))
		}
		total += len(c)
	}
	if total != 1200 {
		t.Fatalf("chunking lost samples: %d of 1200", total)
	}
	if chunkSamples(nil, 500) != nil {
		t.Fatalf("an empty buffer should produce no chunks at all")
	}
}
