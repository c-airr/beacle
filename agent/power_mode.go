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
		// Eco used to feel frozen: metrics every 15s and docker/systemd once a
		// minute, which is what "stats barely update" looked like after the
		// idle timer kicked in. Keep it light, but still live enough that the
		// panel does not look stuck while someone is reading it.
		return syncIntervals{
			metrics:  5 * time.Second,
			ports:    30 * time.Second,
			docker:   30 * time.Second,
			systemd:  30 * time.Second,
			proxy:    30 * time.Second,
			watchdog: 5 * time.Second, // cheap stages only — see affordable()
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
		// Live panel. D-Bus systemd and one-shot docker are cheap enough now
		// that 10–15s keeps docker/services feeling current without the old
		// systemctl spikes.
		return syncIntervals{
			metrics:  2 * time.Second,
			ports:    15 * time.Second,
			docker:   15 * time.Second,
			systemd:  15 * time.Second,
			proxy:    15 * time.Second,
			watchdog: 0,
		}
	}
}
