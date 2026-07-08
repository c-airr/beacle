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
			watchdog: 5 * time.Second,
		}
	case shared.PowerModeSleep:
		return syncIntervals{
			metrics:  60 * time.Second,
			ports:    120 * time.Second,
			docker:   120 * time.Second,
			systemd:  120 * time.Second,
			proxy:    120 * time.Second,
			watchdog: 5 * time.Second,
		}
	default:
		return syncIntervals{
			metrics:  3 * time.Second,
			ports:    10 * time.Second,
			docker:   12 * time.Second,
			systemd:  12 * time.Second,
			proxy:    12 * time.Second,
			watchdog: 0,
		}
	}
}
