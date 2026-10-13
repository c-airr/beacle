package main

import (
	"testing"
	"time"

	"beacle/shared"
)

// filling builds a sample a minute for the given hours, the mount rising by
// perDay percentage points a day from start.
func filling(base time.Time, hours int, start, perDay float64) []shared.MetricSample {
	var out []shared.MetricSample
	for m := 0; m <= hours*60; m++ {
		p := start + perDay*float64(m)/(24*60)
		out = append(out, shared.MetricSample{
			At:     base.Add(time.Duration(m) * time.Minute),
			Mounts: map[string]float64{"/": p, "/data": 40},
		})
	}
	return out
}

func TestForecastSaysWhenAFillingDiskRunsOut(t *testing.T) {
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	// 70% to 79% over three days: 3 points a day, 21 left, 7 days to go.
	samples := filling(base, 72, 70, 3)

	at, ok := forecastFull(samples, "/")
	if !ok {
		t.Fatal("want a forecast for a disk gaining 3 points a day")
	}
	want := base.Add(72*time.Hour + 7*24*time.Hour)
	if d := at.Sub(want); d < -time.Hour || d > time.Hour {
		t.Fatalf("full at %v, want about %v", at, want)
	}
}

func TestForecastStaysQuietForAFlatDisk(t *testing.T) {
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	if _, ok := forecastFull(filling(base, 72, 70, 3), "/data"); ok {
		t.Fatal("a disk that does not grow must have no forecast")
	}
}

func TestForecastNeedsHalfADayOfHistory(t *testing.T) {
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	if _, ok := forecastFull(filling(base, 6, 70, 20), "/"); ok {
		t.Fatal("six hours is too little to extrapolate from")
	}
}

func TestForecastIgnoresSlowGrowthBeyondAMonth(t *testing.T) {
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	// One point a day from 40%: two months to go.
	if _, ok := forecastFull(filling(base, 72, 40, 1), "/"); ok {
		t.Fatal("full in two months is beyond the horizon")
	}
}

func TestForecastStartsOverAfterACleanup(t *testing.T) {
	base := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	// Filled fast for two days, then someone pruned images and it is flat.
	samples := filling(base, 48, 60, 10)
	after := base.Add(48 * time.Hour)
	for m := 1; m <= 24*60; m++ {
		samples = append(samples, shared.MetricSample{
			At:     after.Add(time.Duration(m) * time.Minute),
			Mounts: map[string]float64{"/": 50},
		})
	}
	if _, ok := forecastFull(samples, "/"); ok {
		t.Fatal("growth before the cleanup must not count")
	}
}

func TestSnapshotDisksCarryTheForecast(t *testing.T) {
	h := NewHistory(t.TempDir())
	base := time.Now().UTC().Add(-72 * time.Hour).Truncate(time.Minute)
	h.Backfill("vps1", filling(base, 72, 70, 3))

	m := shared.SystemMetrics{Disks: []shared.DiskUsage{{Mount: "/"}, {Mount: "/data"}}}
	old := m.Disks
	annotateDiskForecast(h, "vps1", &m)

	if m.Disks[0].FullAt == nil {
		t.Fatal("/ is filling and should carry FullAt")
	}
	if m.Disks[1].FullAt != nil {
		t.Fatal("/data is flat and should not")
	}
	if old[0].FullAt != nil {
		t.Fatal("the snapshot's old disk slice must be left alone")
	}
}
