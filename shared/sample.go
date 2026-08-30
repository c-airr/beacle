package shared

import "time"

// SampleFrom turns a live snapshot into the handful of numbers worth keeping.
//
// Shared rather than living in the backend because samples now come from two
// places: the backend records them as snapshots arrive, and agents record their
// own while the panel is unreachable. Two implementations would eventually
// disagree about what "disk" or "network" means, and the chart would show a
// step at the boundary that no server actually did.
func SampleFrom(m SystemMetrics) MetricSample {
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
	return MetricSample{
		At:     at.UTC(),
		CPU:    m.CPUPercent,
		Mem:    m.MemPercent,
		Disk:   worstDisk,
		RxPerS: rx,
		TxPerS: tx,
		Load1:  m.Load1,
	}
}
