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
		// Still live enough that walking back to the panel does not feel frozen.
		// Watchdog is metrics-only (see sync_engine) — ~1ms, not docker.
		return syncIntervals{
			metrics:  3 * time.Second,
			ports:    20 * time.Second,
			docker:   20 * time.Second,
			systemd:  20 * time.Second,
			proxy:    20 * time.Second,
			watchdog: 3 * time.Second,
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
		// Active = the user is looking at the panel. Twice as fast as eco so
		// the live graph and the docker/services lists move while the window is
		// open, without burning a core on a server nobody is watching.
		return syncIntervals{
			metrics:  500 * time.Millisecond,
			ports:    4 * time.Second,
			docker:   5 * time.Second,
			systemd:  4 * time.Second,
			proxy:    4 * time.Second,
			watchdog: 1 * time.Second, // metrics only
		}
	}
}
