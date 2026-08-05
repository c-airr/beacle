//go:build linux

package main

import (
	"sync"
	"time"
)

// cpuMonitor reads /proc/stat on its own clock, completely apart from Metrics
// and the other collectors.
//
// Sampling CPU inside Metrics() was the reason an idle box (load 0.06) showed
// one core at 95%: the window between two readings included whatever the agent
// itself had just done — systemd via systemctl, a docker stats pass, a full
// /proc/*/fd walk for ports — and RequestRefresh then repeated that spiked
// number for up to minCPUWindow. The load average told the truth the whole
// time; the gauge did not.
//
// A one-second ticker that only opens /proc/stat cannot invent that picture.
// Metrics() just copies the latest reading.
type cpuMonitor struct {
	mu sync.RWMutex

	all   cpuSampler
	cores multiSampler

	pct     float64
	perCore []float64
	model   string
	ncores  int

	// Static host facts that Metrics used to re-read from disk every three
	// seconds for no reason.
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
	samples := readPerCoreCPUTimes()

	m.mu.Lock()
	defer m.mu.Unlock()
	m.pct = m.all.sample(idle, total, now)
	if len(samples) == 0 {
		return
	}
	idleN := make([]uint64, len(samples))
	totalN := make([]uint64, len(samples))
	for i, s := range samples {
		idleN[i], totalN[i] = s.idle, s.total
	}
	m.perCore = m.cores.sample(idleN, totalN, now)
	if m.ncores == 0 {
		m.ncores = len(samples)
	}
}

func (m *cpuMonitor) snapshot() (pct float64, perCore []float64, model string, cores int, host, osName, kernel string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	perCore = append([]float64(nil), m.perCore...)
	return m.pct, perCore, m.model, m.ncores, m.hostname, m.osName, m.kernel
}
