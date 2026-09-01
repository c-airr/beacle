package main

import (
	"testing"
	"time"
)

func mkLog(t *testing.T, runs ...uptimeRun) *UptimeLog {
	t.Helper()
	u := NewUptimeLog(t.TempDir())
	u.runs = runs
	// Keep the live run out of the way of the fixtures.
	now := time.Now().UTC().Add(24 * time.Hour)
	u.current = uptimeRun{From: now, To: now}
	return u
}

func at(h, m int) time.Time {
	return time.Date(2026, 9, 1, h, m, 0, 0, time.UTC)
}

func TestAClosedPanelIsReportedAsPanelDowntime(t *testing.T) {
	// Ran until 02:00, started again at 09:00: the seven hours in between are
	// a period nobody was recording, not a server that fell over.
	u := mkLog(t,
		uptimeRun{From: at(0, 0), To: at(2, 0)},
		uptimeRun{From: at(9, 0), To: at(12, 0)},
	)
	down := u.DownFrom(at(0, 0), at(12, 0))
	if len(down) != 1 {
		t.Fatalf("want 1 stretch of downtime, got %d: %+v", len(down), down)
	}
	if !down[0].From.Equal(at(2, 0)) || !down[0].To.Equal(at(9, 0)) {
		t.Fatalf("wrong window: %v -> %v", down[0].From, down[0].To)
	}
}

func TestContinuousRunningReportsNoDowntime(t *testing.T) {
	u := mkLog(t, uptimeRun{From: at(0, 0), To: at(12, 0)})
	if down := u.DownFrom(at(1, 0), at(11, 0)); len(down) != 0 {
		t.Fatalf("want no downtime, got %+v", down)
	}
}

func TestARestartIsNotDowntime(t *testing.T) {
	// Two runs a minute apart is the panel restarting, not an absence worth
	// drawing on a chart.
	u := mkLog(t,
		uptimeRun{From: at(0, 0), To: at(6, 0)},
		uptimeRun{From: at(6, 1), To: at(12, 0)},
	)
	if down := u.DownFrom(at(0, 0), at(12, 0)); len(down) != 0 {
		t.Fatalf("a restart should not read as downtime, got %+v", down)
	}
}

func TestDowntimeAtTheEndOfTheWindowIsReported(t *testing.T) {
	// The panel stopped and never came back inside the window.
	u := mkLog(t, uptimeRun{From: at(0, 0), To: at(3, 0)})
	down := u.DownFrom(at(0, 0), at(12, 0))
	if len(down) != 1 || !down[0].From.Equal(at(3, 0)) || !down[0].To.Equal(at(12, 0)) {
		t.Fatalf("want 03:00->12:00, got %+v", down)
	}
}

func TestDowntimeBeforeTheFirstRunIsReported(t *testing.T) {
	// Asking about a window that starts before any record exists: nothing was
	// recording then either.
	u := mkLog(t, uptimeRun{From: at(6, 0), To: at(12, 0)})
	down := u.DownFrom(at(0, 0), at(12, 0))
	if len(down) != 1 || !down[0].From.Equal(at(0, 0)) || !down[0].To.Equal(at(6, 0)) {
		t.Fatalf("want 00:00->06:00, got %+v", down)
	}
}

func TestRunsSurviveARestartOfTheBackend(t *testing.T) {
	dir := t.TempDir()
	u := NewUptimeLog(dir)
	u.runs = []uptimeRun{{From: at(0, 0), To: at(2, 0)}}
	u.persist()

	reopened := NewUptimeLog(dir)
	if len(reopened.runs) != 2 {
		// The fixture run plus the run that was live when persist() was called.
		t.Fatalf("want the persisted runs back, got %d: %+v", len(reopened.runs), reopened.runs)
	}
}

func TestOverlappingRunsDoNotProduceNegativeGaps(t *testing.T) {
	u := mkLog(t,
		uptimeRun{From: at(0, 0), To: at(8, 0)},
		uptimeRun{From: at(4, 0), To: at(12, 0)},
	)
	if down := u.DownFrom(at(0, 0), at(12, 0)); len(down) != 0 {
		t.Fatalf("overlapping runs cover the window, got %+v", down)
	}
}
