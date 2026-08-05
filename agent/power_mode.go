package main

import (
	"time"

	"beacle/shared"
)

type syncIntervals struct {
	metrics  time.Duration
	ports    time.Duration
	docker   time.Duration
	systemd  time.Duration
	proxy    time.Duration
	watchdog time.Duration
}

func intervalsFor(mode shared.PowerMode) syncIntervals {
	switch mode {
	case shared.PowerModeEco:
		return syncIntervals{
			metrics:  5 * time.Second,
			ports:    30 * time.Second,
			docker:   45 * time.Second,
			systemd:  30 * time.Second,
			proxy:    30 * time.Second,
			// No watchdog: even "cheap" stages every 5s still produced visible
			// spikes on the host gauge. Interval ticks + RequestRefresh cover it.
			watchdog: 0,
		}
	case shared.PowerModeSleep:
		return syncIntervals{
			metrics:  30 * time.Second,
			ports:    90 * time.Second,
			docker:   90 * time.Second,
			systemd:  90 * time.Second,
			proxy:    90 * time.Second,
			watchdog: 0,
		}
	default:
		return syncIntervals{
			metrics:  2 * time.Second,
			ports:    15 * time.Second,
			docker:   20 * time.Second,
			systemd:  15 * time.Second,
			proxy:    15 * time.Second,
			watchdog: 0,
		}
	}
}
