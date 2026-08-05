//go:build linux

package main

import (
	"sync"
	"time"
)

// cpuMonitor reads /proc/stat on its own clock, completely apart from Metrics
// and the other collectors, and subtracts this process's own CPU ticks so the
// panel does not report the agent's collection work as host load.
type cpuMonitor struct {
	mu sync.RWMutex

	cores multiSampler

	pct     float64
	perCore []float64
	model   string
	ncores  int

	prevIdle  uint64
	prevTotal uint64
	prevSelf  uint64
	hasPrev   bool
	lastAt    time.Time

	hostname string
	osName   string
	kernel   string
}

const cpuTickEvery = time.Second

func newCPUMonitor() *cpuMonitor {
	m := &cpuMonitor{}
	m.hostname, _ = osHostname()
	m.osName = readPrettyName()
	m.kernel = readKernelRelease()
	m.model, m.ncores = cpuModel()
	m.tick()
	go m.loop()
	return m
}

func (m *cpuMonitor) loop() {
	t := time.NewTicker(cpuTickEvery)
	defer t.Stop()
	for range t.C {
		m.tick()
	}
}

func (m *cpuMonitor) tick() {
	now := time.Now()
	idle, total := readCPUTimes()
	self := processCPUTicks()
	samples := readPerCoreCPUTimes()

	m.mu.Lock()
	defer m.mu.Unlock()

	rawOverall := 0.0
	adjusted := 0.0
	if m.hasPrev && (m.lastAt.IsZero() || now.Sub(m.lastAt) >= minCPUWindow) {
		if total > m.prevTotal {
			dTotal := float64(total - m.prevTotal)
			dIdle := float64(0)
			if idle >= m.prevIdle {
				dIdle = float64(idle - m.prevIdle)
			}
			dSelf := float64(0)
			if self >= m.prevSelf {
				dSelf = float64(self - m.prevSelf)
			}
			if dTotal > 0 {
				rawBusy := dTotal - dIdle
				if rawBusy < 0 {
					rawBusy = 0
				}
				rawOverall = rawBusy / dTotal * 100
				adjBusy := rawBusy - dSelf
				if adjBusy < 0 {
					adjBusy = 0
				}
				adjusted = adjBusy / dTotal * 100
			}
			if rawOverall > 100 {
				rawOverall = 100
			}
			if adjusted > 100 {
				adjusted = 100
			}
			m.prevIdle, m.prevTotal, m.prevSelf = idle, total, self
			m.lastAt = now
			m.pct = adjusted
		} else {
			m.prevIdle, m.prevTotal, m.prevSelf = idle, total, self
			m.lastAt = now
		}
	} else if !m.hasPrev {
		m.prevIdle, m.prevTotal, m.prevSelf = idle, total, self
		m.hasPrev = true
		m.lastAt = now
		m.pct = 0
	}
	// else: inside minCPUWindow — keep m.pct as-is, do not consume counters

	if len(samples) > 0 {
		idleN := make([]uint64, len(samples))
		totalN := make([]uint64, len(samples))
		for i, s := range samples {
			idleN[i], totalN[i] = s.idle, s.total
		}
		rawCores := m.cores.sample(idleN, totalN, now)
		m.perCore = scaleOutSelf(rawCores, rawOverall, m.pct)
		if m.ncores == 0 {
			m.ncores = len(samples)
		}
	}
}

// scaleOutSelf keeps per-core bars consistent with an overall figure that
// already had this process removed.
func scaleOutSelf(cores []float64, rawOverall, adjustedOverall float64) []float64 {
	if len(cores) == 0 {
		return cores
	}
	out := append([]float64(nil), cores...)
	if rawOverall <= 0.01 {
		return out
	}
	factor := adjustedOverall / rawOverall
	if factor < 0 {
		factor = 0
	}
	if factor > 1 {
		factor = 1
	}
	for i := range out {
		v := out[i] * factor
		if v < 0 {
			v = 0
		}
		if v > 100 {
			v = 100
		}
		out[i] = v
	}
	return out
}

func (m *cpuMonitor) snapshot() (pct float64, perCore []float64, model string, cores int, host, osName, kernel string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	perCore = append([]float64(nil), m.perCore...)
	return m.pct, perCore, m.model, m.ncores, m.hostname, m.osName, m.kernel
}
