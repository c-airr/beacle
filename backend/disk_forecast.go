package main

import (
	"time"

	"beacle/shared"
)

// Disk forecast: "full in about 4 days" next to a disk, from its recorded
// history. A threshold alert at 90% fires when it is already urgent; the trend
// says so while there is still time to do something calm about it.

const (
	// How far back the trend looks. Long enough to average out a day's rhythm
	// of logs and backups, short enough to follow a change in what the box does.
	forecastWindow = 72 * time.Hour
	// Below this much history the slope is mostly noise.
	forecastMinSpan    = 12 * time.Hour
	forecastMinSamples = 60
	// A disk that grows by less than this in the whole window is not filling,
	// whatever the slope says; extrapolating a tenth of a percent to "full in
	// two years" helps nobody.
	forecastMinRise = 0.5
	// A drop this large between two samples is a cleanup (logs rotated, images
	// pruned). The trend before it is about a disk that no longer exists.
	forecastCleanupDrop = 2.0
	// Further out than this the forecast is too uncertain to show.
	forecastHorizon = 30 * 24 * time.Hour
	// Recomputed at most this often per server; the answer moves slowly.
	forecastRefresh = 10 * time.Minute
)

// forecastFull fits a straight line to one mount's used percent over the
// recent window and returns when it reaches 100%.
func forecastFull(samples []shared.MetricSample, mount string) (time.Time, bool) {
	if len(samples) == 0 {
		return time.Time{}, false
	}
	from := samples[len(samples)-1].At.Add(-forecastWindow)

	type point struct {
		at time.Time
		p  float64
	}
	var pts []point
	for _, s := range samples {
		if s.At.Before(from) {
			continue
		}
		p, ok := s.Mounts[mount]
		if !ok {
			continue
		}
		if n := len(pts); n > 0 && pts[n-1].p-p >= forecastCleanupDrop {
			pts = pts[:0]
		}
		pts = append(pts, point{s.At, p})
	}
	if len(pts) < forecastMinSamples {
		return time.Time{}, false
	}
	first, last := pts[0], pts[len(pts)-1]
	span := last.at.Sub(first.at)
	if span < forecastMinSpan {
		return time.Time{}, false
	}

	// Least squares in hours since the first point.
	var n, sx, sy, sxx, sxy float64
	for _, pt := range pts {
		x := pt.at.Sub(first.at).Hours()
		n++
		sx += x
		sy += pt.p
		sxx += x * x
		sxy += x * pt.p
	}
	den := n*sxx - sx*sx
	if den == 0 {
		return time.Time{}, false
	}
	slope := (n*sxy - sx*sy) / den // percent per hour
	if slope <= 0 || slope*span.Hours() < forecastMinRise {
		return time.Time{}, false
	}
	left := 100 - last.p
	if left <= 0 {
		return time.Time{}, false
	}
	eta := time.Duration(left / slope * float64(time.Hour))
	if eta > forecastHorizon {
		return time.Time{}, false
	}
	return last.at.Add(eta), true
}

type diskForecast struct {
	at     time.Time
	mounts map[string]bool // what it was computed for
	full   map[string]time.Time
}

// DiskForecast returns when each mount is expected to be full, for the mounts
// that are filling fast enough to say. Cached per server; a disk that was not
// there when the cache was filled forces a recompute instead of going without
// a forecast for ten minutes.
func (h *History) DiskForecast(vpsID string, mounts []string, now time.Time) map[string]time.Time {
	h.mu.Lock()
	defer h.mu.Unlock()

	if c, ok := h.forecasts[vpsID]; ok && now.Sub(c.at) < forecastRefresh && covers(c.mounts, mounts) {
		return c.full
	}
	all := h.samples[vpsID]
	c := diskForecast{at: now, mounts: map[string]bool{}, full: map[string]time.Time{}}
	for _, m := range mounts {
		c.mounts[m] = true
		if at, ok := forecastFull(all, m); ok {
			c.full[m] = at
		}
	}
	h.forecasts[vpsID] = c
	return c.full
}

func covers(have map[string]bool, want []string) bool {
	for _, m := range want {
		if !have[m] {
			return false
		}
	}
	return true
}

// annotateDiskForecast sets FullAt on the snapshot's disks. Builds a new slice:
// the old one is shared with the snapshot readers may still hold.
func annotateDiskForecast(history *History, vpsID string, m *shared.SystemMetrics) {
	if history == nil || len(m.Disks) == 0 {
		return
	}
	mounts := make([]string, len(m.Disks))
	for i, d := range m.Disks {
		mounts[i] = d.Mount
	}
	full := history.DiskForecast(vpsID, mounts, time.Now())
	disks := make([]shared.DiskUsage, len(m.Disks))
	for i, d := range m.Disks {
		d.FullAt = nil
		if at, ok := full[d.Mount]; ok {
			at := at
			d.FullAt = &at
		}
		disks[i] = d
	}
	m.Disks = disks
}
