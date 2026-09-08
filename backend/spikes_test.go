package main

import (
	"testing"
	"time"

	"beacle/shared"
)

func spikeAt(min int, metric string, cpu float64) shared.SpikeRecord {
	base := time.Now().UTC().Add(-2 * time.Hour).Truncate(time.Minute)
	return shared.SpikeRecord{
		At:       base.Add(time.Duration(min) * time.Minute),
		Metric:   metric,
		Value:    cpu,
		Baseline: 8,
		Top: []shared.SpikeProcess{
			{PID: 1234, Name: "ffmpeg", CPUPercent: cpu},
		},
	}
}

func TestASpikeIsStoredAndComesBack(t *testing.T) {
	s := NewSpikes(t.TempDir())
	if n := s.Record("vps1", []shared.SpikeRecord{spikeAt(0, "cpu", 92)}); n != 1 {
		t.Fatalf("want 1 recorded, got %d", n)
	}
	got := s.Query("vps1", time.Time{}, time.Time{})
	if len(got) != 1 || got[0].Top[0].Name != "ffmpeg" {
		t.Fatalf("record did not come back intact: %+v", got)
	}
}

func TestAResentBatchIsNotStoredTwice(t *testing.T) {
	// Agents re-send what they could not confirm was delivered, by design:
	// losing an incident is worse than receiving it twice.
	s := NewSpikes(t.TempDir())
	batch := []shared.SpikeRecord{spikeAt(0, "cpu", 92), spikeAt(5, "cpu", 88)}
	if n := s.Record("vps1", batch); n != 2 {
		t.Fatalf("first delivery: want 2, got %d", n)
	}
	if n := s.Record("vps1", batch); n != 0 {
		t.Fatalf("a re-sent batch should add nothing, added %d", n)
	}
	if got := s.Query("vps1", time.Time{}, time.Time{}); len(got) != 2 {
		t.Fatalf("want 2 after a duplicate delivery, got %d", len(got))
	}
}

func TestTwoMetricsSpikingAtOnceAreBothKept(t *testing.T) {
	// CPU and memory jumping in the same minute is one event with two
	// symptoms; deduplicating on time alone would throw one away.
	s := NewSpikes(t.TempDir())
	n := s.Record("vps1", []shared.SpikeRecord{
		spikeAt(0, "cpu", 92),
		spikeAt(0, "mem", 90),
	})
	if n != 2 {
		t.Fatalf("want both metrics kept, got %d", n)
	}
}

func TestClickingTheChartFindsTheNearbySpike(t *testing.T) {
	// A reader points at a peak, not at a timestamp. The record a minute
	// either side is the one they mean.
	s := NewSpikes(t.TempDir())
	s.Record("vps1", []shared.SpikeRecord{spikeAt(30, "cpu", 92)})

	target := spikeAt(30, "cpu", 0).At.Add(40 * time.Second)
	if got := s.Nearest("vps1", target, 2*time.Minute); got == nil {
		t.Fatal("a click 40s from a spike should find it")
	}
	far := spikeAt(30, "cpu", 0).At.Add(20 * time.Minute)
	if got := s.Nearest("vps1", far, 2*time.Minute); got != nil {
		t.Fatalf("a click 20 minutes away should find nothing, got %+v", got)
	}
}

func TestTheClosestSpikeWinsWhenSeveralAreNear(t *testing.T) {
	s := NewSpikes(t.TempDir())
	s.Record("vps1", []shared.SpikeRecord{
		spikeAt(10, "cpu", 60),
		spikeAt(13, "cpu", 95),
	})
	at := spikeAt(13, "cpu", 0).At.Add(30 * time.Second)
	got := s.Nearest("vps1", at, 10*time.Minute)
	if got == nil || got.Value != 95 {
		t.Fatalf("want the nearer spike (95), got %+v", got)
	}
}

func TestNonsenseTimestampsAreRejected(t *testing.T) {
	s := NewSpikes(t.TempDir())
	now := time.Now().UTC()
	n := s.Record("vps1", []shared.SpikeRecord{
		{At: time.Time{}, Metric: "cpu"},                   // zero
		{At: now.Add(-30 * 24 * time.Hour), Metric: "cpu"}, // past retention
		{At: now.Add(48 * time.Hour), Metric: "cpu"},       // clock set forward
		{At: now.Add(-10 * time.Minute), Metric: "cpu"},    // the good one
	})
	if n != 1 {
		t.Fatalf("want only the valid record, got %d", n)
	}
}

func TestRecordsSurviveARestart(t *testing.T) {
	dir := t.TempDir()
	s := NewSpikes(dir)
	s.Record("vps1", []shared.SpikeRecord{spikeAt(0, "cpu", 92)})

	reopened := NewSpikes(dir)
	got := reopened.Query("vps1", time.Time{}, time.Time{})
	if len(got) != 1 {
		t.Fatalf("want the record back after restart, got %d", len(got))
	}
	if len(got[0].Top) != 1 || got[0].Top[0].PID != 1234 {
		t.Fatalf("processes did not survive the round trip: %+v", got[0].Top)
	}
}

func TestForgettingAServerRemovesItsRecords(t *testing.T) {
	s := NewSpikes(t.TempDir())
	s.Record("vps1", []shared.SpikeRecord{spikeAt(0, "cpu", 92)})
	s.Forget("vps1")
	if got := s.Query("vps1", time.Time{}, time.Time{}); len(got) != 0 {
		t.Fatalf("want nothing after Forget, got %d", len(got))
	}
}

func TestQueryRespectsTheWindow(t *testing.T) {
	s := NewSpikes(t.TempDir())
	s.Record("vps1", []shared.SpikeRecord{
		spikeAt(0, "cpu", 92),
		spikeAt(30, "cpu", 88),
		spikeAt(60, "cpu", 91),
	})
	from := spikeAt(20, "cpu", 0).At
	to := spikeAt(40, "cpu", 0).At
	if got := s.Query("vps1", from, to); len(got) != 1 {
		t.Fatalf("want the one spike inside the window, got %d", len(got))
	}
}
