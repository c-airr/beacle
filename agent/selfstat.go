package main

import (
	"runtime"
	"sync"
	"time"
)

// Self-measurement, so a question like "why is this agent using CPU" has an
// answer that does not depend on guessing from the outside. Every collection
// stage reports how long it took and how often it ran; the systemd layer
// reports which path it is actually on, because falling back from D-Bus to
// spawning systemctl is invisible from the panel and undoes the whole reason
// the D-Bus path exists.
//
// Read it through the backend proxy:
//   curl http://127.0.0.1:9930/api/vps/<id>/agent/debug/selfstat

type stageStat struct {
	Runs    int64   `json:"runs"`
	LastMs  float64 `json:"last_ms"`
	MaxMs   float64 `json:"max_ms"`
	TotalMs float64 `json:"total_ms"`
}

type selfStatState struct {
	mu     sync.Mutex
	stages map[string]*stageStat

	systemdPath string // "dbus" | "systemctl" | "" until the first collection
	systemdNote string // why the fallback happened, when it did
	powerMode   string

	startedAt time.Time
}

var selfStat = &selfStatState{
	stages:    map[string]*stageStat{},
	startedAt: time.Now(),
}

// track times a stage. Call as: defer track("systemd")()
func track(stage string) func() {
	start := time.Now()
	return func() {
		ms := float64(time.Since(start).Microseconds()) / 1000

		selfStat.mu.Lock()
		defer selfStat.mu.Unlock()
		s := selfStat.stages[stage]
		if s == nil {
			s = &stageStat{}
			selfStat.stages[stage] = s
		}
		s.Runs++
		s.LastMs = ms
		s.TotalMs += ms
		if ms > s.MaxMs {
			s.MaxMs = ms
		}
	}
}

// lastStageMs is how long a stage took the last time it ran, or 0 when it has
// never run. The watchdog uses it to avoid polling something that costs more
// than the interval it polls on.
func lastStageMs(stage string) float64 {
	selfStat.mu.Lock()
	defer selfStat.mu.Unlock()
	if s := selfStat.stages[stage]; s != nil {
		return s.LastMs
	}
	return 0
}

// noteSystemdPath records how the last systemd read was served. The note is
// only set when something went wrong, so an empty one means D-Bus is fine.
func noteSystemdPath(path, note string) {
	selfStat.mu.Lock()
	defer selfStat.mu.Unlock()
	selfStat.systemdPath = path
	selfStat.systemdNote = note
}

// notePowerMode keeps the reported mode next to the timings, because the same
// stage costing 30ms is fine every 30s and not fine every 3s.
func notePowerMode(mode string) {
	selfStat.mu.Lock()
	defer selfStat.mu.Unlock()
	selfStat.powerMode = mode
}

// SelfStat is the reply shape. Everything here is cheap to produce; nothing in
// it costs more than reading a counter or one file in /proc.
type SelfStat struct {
	Version     string                `json:"version"`
	UptimeSec   float64               `json:"uptime_sec"`
	Goroutines  int                   `json:"goroutines"`
	SystemdPath string                `json:"systemd_path"`
	SystemdNote string                `json:"systemd_note,omitempty"`
	CPUSeconds  float64               `json:"cpu_seconds"`
	CPUPercent  float64               `json:"cpu_percent_since_start"`
	HeapMB      float64               `json:"heap_mb"`
	Stages      map[string]*stageStat `json:"stages"`
	PowerMode   string                `json:"power_mode,omitempty"`
}

func collectSelfStat() SelfStat {
	selfStat.mu.Lock()
	stages := make(map[string]*stageStat, len(selfStat.stages))
	for k, v := range selfStat.stages {
		copied := *v
		stages[k] = &copied
	}
	path, note, started := selfStat.systemdPath, selfStat.systemdNote, selfStat.startedAt
	mode := selfStat.powerMode
	selfStat.mu.Unlock()

	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)

	uptime := time.Since(started).Seconds()
	cpu := processCPUSeconds()

	out := SelfStat{
		Version:     AgentVersion,
		UptimeSec:   uptime,
		Goroutines:  runtime.NumGoroutine(),
		SystemdPath: path,
		SystemdNote: note,
		CPUSeconds:  cpu,
		HeapMB:      float64(mem.HeapAlloc) / (1024 * 1024),
		Stages:      stages,
		PowerMode:   mode,
	}
	if uptime > 0 {
		// Averaged over the whole run: a single spike will not show here, but a
		// stage that burns CPU on every tick will.
		out.CPUPercent = cpu / uptime * 100
	}
	return out
}
