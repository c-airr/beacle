package main

import (
	"testing"
	"time"

	"beacle/shared"
)

func histSample(base time.Time, min int, cpu float64) shared.MetricSample {
	return shared.MetricSample{At: base.Add(time.Duration(min) * time.Minute).UTC(), CPU: cpu}
}

func TestBackfillFillsAGapLeftWhileThePanelWasClosed(t *testing.T) {
	h := NewHistory(t.TempDir())
	base := time.Now().UTC().Add(-3 * time.Hour).Truncate(time.Minute)

	// The panel was running, then closed for an hour, then opened again.
	h.Record("vps1", histSample(base, 0, 10))
	h.Record("vps1", histSample(base, 60, 40))

	// The agent hands over what it recorded during the hour nobody was there.
	var gap []shared.MetricSample
	for m := 1; m < 60; m++ {
		gap = append(gap, histSample(base, m, 20))
	}
	added := h.Backfill("vps1", gap)
	if added != 59 {
		t.Fatalf("want 59 samples recorded, got %d", added)
	}

	got := h.Query("vps1", base.Add(-time.Minute), base.Add(61*time.Minute))
	if len(got) != 61 {
		t.Fatalf("want a continuous hour (61 samples), got %d", len(got))
	}
	for i := 1; i < len(got); i++ {
		if !got[i].At.After(got[i-1].At) {
			t.Fatalf("history is out of order at %d: %v then %v", i, got[i-1].At, got[i].At)
		}
	}
}

func TestResentSamplesAreNotRecordedTwice(t *testing.T) {
	// An agent re-sends a chunk it could not confirm was delivered. That is by
	// design — losing samples is worse than sending them twice — so the
	// duplicates have to be dropped here.
	h := NewHistory(t.TempDir())
	base := time.Now().UTC().Add(-time.Hour).Truncate(time.Minute)

	batch := []shared.MetricSample{
		histSample(base, 0, 10),
		histSample(base, 1, 11),
		histSample(base, 2, 12),
	}
	if added := h.Backfill("vps1", batch); added != 3 {
		t.Fatalf("first delivery: want 3, got %d", added)
	}
	if added := h.Backfill("vps1", batch); added != 0 {
		t.Fatalf("re-sent chunk should add nothing, added %d", added)
	}
	if got := h.Query("vps1", time.Time{}, time.Time{}); len(got) != 3 {
		t.Fatalf("want 3 samples after a duplicate delivery, got %d", len(got))
	}
}

func TestBackfillDoesNotDisplaceLiveSamples(t *testing.T) {
	// A backfilled minute must never overwrite what the backend recorded live
	// for that same minute — the live one was measured, this one is a guess at
	// the same instant.
	h := NewHistory(t.TempDir())
	base := time.Now().UTC().Add(-time.Hour).Truncate(time.Minute)

	h.Record("vps1", histSample(base, 0, 99))
	h.Backfill("vps1", []shared.MetricSample{histSample(base, 0, 1)})

	got := h.Query("vps1", time.Time{}, time.Time{})
	if len(got) != 1 {
		t.Fatalf("want 1 sample for that minute, got %d", len(got))
	}
	if got[0].CPU != 99 {
		t.Fatalf("the live sample was replaced by a backfilled one (cpu %v)", got[0].CPU)
	}
}

func TestBackfillRejectsNonsenseTimestamps(t *testing.T) {
	h := NewHistory(t.TempDir())
	now := time.Now().UTC()

	added := h.Backfill("vps1", []shared.MetricSample{
		{At: time.Time{}, CPU: 5},                        // zero
		{At: now.Add(-30 * 24 * time.Hour), CPU: 5},      // past retention
		{At: now.Add(48 * time.Hour), CPU: 5},            // clock set forward
		{At: now.Add(-10 * time.Minute), CPU: 5},         // the one good sample
	})
	if added != 1 {
		t.Fatalf("want only the valid sample recorded, got %d", added)
	}
}

func TestBackfillSurvivesARestart(t *testing.T) {
	// Samples handed over are only useful if they are still there tomorrow.
	dir := t.TempDir()
	base := time.Now().UTC().Add(-time.Hour).Truncate(time.Minute)

	h := NewHistory(dir)
	h.Backfill("vps1", []shared.MetricSample{
		histSample(base, 0, 10),
		histSample(base, 1, 11),
	})

	reopened := NewHistory(dir)
	got := reopened.Query("vps1", time.Time{}, time.Time{})
	if len(got) != 2 {
		t.Fatalf("want 2 samples after restart, got %d", len(got))
	}
}

func TestEmptyBackfillIsANoOp(t *testing.T) {
	h := NewHistory(t.TempDir())
	if added := h.Backfill("vps1", nil); added != 0 {
		t.Fatalf("want 0, got %d", added)
	}
}
