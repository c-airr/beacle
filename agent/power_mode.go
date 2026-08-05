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
			metrics:  15 * time.Second,
			ports:    45 * time.Second,
			docker:   60 * time.Second,
			systemd:  60 * time.Second,
			proxy:    60 * time.Second,
			// Watchdog off: even a "cheap" docker read (~200ms) every 5s was
			// twelve collections a minute and showed up as 10–20% spikes on an
			// idle box. Panel actions already call RequestRefresh.
			watchdog: 0,
		}
	case shared.PowerModeSleep:
		return syncIntervals{
			metrics:  60 * time.Second,
			ports:    120 * time.Second,
			docker:   120 * time.Second,
			systemd:  120 * time.Second,
			proxy:    120 * time.Second,
			watchdog: 0,
		}
	default:
		// metrics stay fast because that is the live graph. The rest describe
		// things that change when someone changes them, and every one of those
		// pushes is answered immediately after a panel action anyway
		// (RequestRefresh), so polling them hard only cost CPU.
		return syncIntervals{
			metrics:  3 * time.Second,
			ports:    30 * time.Second,
			docker:   30 * time.Second,
			systemd:  30 * time.Second,
			proxy:    30 * time.Second,
			watchdog: 0,
		}
	}
}
