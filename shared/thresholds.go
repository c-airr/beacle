package shared

// Alerting thresholds shared by backend evaluation and UI display.
const (
	CPUHighPercent     = 85.0
	MemHighPercent     = 90.0
	DiskHighPercent    = 90.0
	HighLoadCPUPercent = 75.0 // marker turns yellow above this

	// SustainedSeconds: CPU and RAM have to stay over the threshold this long
	// before an alert fires. A build, a backup or a container start briefly
	// pins a core at 100% — alerting on a single sample makes the alert list
	// noise, and noisy alerts get ignored. Disk usage has no such spikes, so it
	// still fires on the first reading.
	SustainedSeconds = 10

	// Clear thresholds sit below the firing ones so an alert does not flap.
	// A host parked at exactly 90% RAM crosses back and forth on every sample,
	// and since each crossing opens a brand new alert, that alone produced
	// dozens of rows reading "RAM above 90% (now 90%)". Recovery has to mean
	// the pressure actually eased, not that one reading rounded down.
	CPUClearPercent  = 75.0
	MemClearPercent  = 82.0
	DiskClearPercent = 85.0

	// OfflineAfterSec: how long the agent WebSocket may stay down before an
	// offline alert fires and the last snapshot is dropped. The VPS status
	// itself flips as soon as the socket goes away — this is only the grace
	// window for alerting, so a short reconnect does not spam alerts.
	// Live sockets are never marked offline regardless of this value.
	OfflineAfterSec  = 45
	DefaultAgentPort = 8931

	// RestartExpectSec: how long a user-initiated reboot/poweroff marker is
	// believed. While it holds, the offline watcher shows restarting (or
	// powered_off) and fires no alerts. Past it the box should have been
	// back long ago, so the marker expires into a normal offline.
	RestartExpectSec = 900
	// RestartLiveClearSec: a rebooted agent drops its socket within seconds.
	// If the socket is still live this long after the marker was set, the
	// reboot never happened (or the host is already back without
	// re-registering cleanly) and the marker is dropped.
	RestartLiveClearSec = 120
)

// EffectiveThresholds resolves the firing/clearing thresholds for one server:
// per-VPS overrides win, globals fill the rest. A custom firing threshold
// drags its clear threshold below it (5 points of hysteresis), because a
// custom high of 60 with the global clear of 75 would flap on every sample.
func (v VPS) EffectiveThresholds() (cpuHigh, memHigh, diskHigh, cpuClear, memClear, diskClear float64) {
	cpuHigh, memHigh, diskHigh = CPUHighPercent, MemHighPercent, DiskHighPercent
	cpuClear, memClear, diskClear = CPUClearPercent, MemClearPercent, DiskClearPercent
	if v.Thresholds == nil {
		return cpuHigh, memHigh, diskHigh, cpuClear, memClear, diskClear
	}
	if v.Thresholds.CPUHigh > 0 {
		cpuHigh = v.Thresholds.CPUHigh
		if cpuClear >= cpuHigh {
			cpuClear = cpuHigh - 5
		}
	}
	if v.Thresholds.MemHigh > 0 {
		memHigh = v.Thresholds.MemHigh
		if memClear >= memHigh {
			memClear = memHigh - 5
		}
	}
	if v.Thresholds.DiskHigh > 0 {
		diskHigh = v.Thresholds.DiskHigh
		if diskClear >= diskHigh {
			diskClear = diskHigh - 5
		}
	}
	if cpuClear < 0 {
		cpuClear = 0
	}
	if memClear < 0 {
		memClear = 0
	}
	if diskClear < 0 {
		diskClear = 0
	}
	return cpuHigh, memHigh, diskHigh, cpuClear, memClear, diskClear
}
