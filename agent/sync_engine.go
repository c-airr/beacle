package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"beacle/shared"
)

type syncKind int

const (
	syncMetrics syncKind = iota
	syncPorts
	syncDocker
	syncSystemd
	syncProxy
)

// SyncEngine pushes typed snapshot frames over the agent WebSocket. Intervals
// are owned entirely by the agent and selected by power mode.
type SyncEngine struct {
	cfg      *Config
	reporter *Reporter
	writeCh  chan<- []byte

	// done is closed when the session this engine belongs to ends. Every send
	// watches it, so a push that is already in flight when the socket drops
	// gives up instead of writing into a channel nobody will read again.
	done <-chan struct{}

	mu          sync.RWMutex
	mode        shared.PowerMode
	modeVersion atomic.Uint32

	pushMu     sync.Mutex
	pushQueued bool

	fpMu sync.Mutex
	fp   struct {
		metrics, docker, systemd, proxy, ports string
	}
}

func NewSyncEngine(cfg *Config, reporter *Reporter, writeCh chan<- []byte) *SyncEngine {
	return &SyncEngine{
		cfg:      cfg,
		reporter: reporter,
		writeCh:  writeCh,
		mode:     shared.PowerModeActive,
	}
}

func (e *SyncEngine) Run(ctx context.Context) {
	e.mu.Lock()
	e.done = ctx.Done()
	e.mu.Unlock()
	go e.loop(ctx, syncMetrics)
	go e.loop(ctx, syncPorts)
	go e.loop(ctx, syncDocker)
	go e.loop(ctx, syncSystemd)
	go e.loop(ctx, syncProxy)
	go e.watchdog(ctx)
	e.PushAll()
	<-ctx.Done()
}

func (e *SyncEngine) SetPowerMode(mode shared.PowerMode) {
	if mode == "" {
		mode = shared.PowerModeActive
	}
	e.mu.Lock()
	e.mode = mode
	e.mu.Unlock()
	notePowerMode(string(mode))
	e.modeVersion.Add(1)
	e.schedulePushAll()
}

func (e *SyncEngine) RequestRefresh() {
	e.schedulePushAll()
}

// schedulePushAll coalesces wake-up storms: SetPowerMode and RequestRefresh
// both used to fire PushAll at once, so coming back from eco ran docker/systemd
// twice back-to-back and the panel sat on a spinner for several seconds.
func (e *SyncEngine) schedulePushAll() {
	e.pushMu.Lock()
	if e.pushQueued {
		e.pushMu.Unlock()
		return
	}
	e.pushQueued = true
	e.pushMu.Unlock()
	go func() {
		time.Sleep(30 * time.Millisecond)
		e.pushMu.Lock()
		e.pushQueued = false
		e.pushMu.Unlock()
		e.PushAll()
	}()
}

func (e *SyncEngine) intervals() syncIntervals {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return intervalsFor(e.mode)
}

func (e *SyncEngine) loop(ctx context.Context, kind syncKind) {
	for {
		if ctx.Err() != nil {
			return
		}
		iv := e.intervalFor(kind)
		if iv <= 0 {
			iv = time.Second
		}
		ticker := time.NewTicker(iv)
		select {
		case <-ctx.Done():
			ticker.Stop()
			return
		case <-ticker.C:
			ticker.Stop()
			if err := e.pusher(kind)(); err != nil {
				log.Printf("sync %d: %v", kind, err)
			}
		}
	}
}

func (e *SyncEngine) intervalFor(kind syncKind) time.Duration {
	iv := e.intervals()
	var base time.Duration
	var stage string
	switch kind {
	case syncPorts:
		base, stage = iv.ports, "ports"
	case syncDocker:
		base, stage = iv.docker, "docker"
	case syncSystemd:
		base, stage = iv.systemd, "systemd"
	case syncProxy:
		base, stage = iv.proxy, "proxy"
	default:
		base, stage = iv.metrics, "metrics"
	}
	return stretchExpensive(base, stage)
}

// stretchExpensive backs off a stage whose last run was slow. A systemd read
// that fell through to spawning systemctl was measured at ~1.8s — polling that
// every 30s is already a lot, and anything faster quietly pins a core for a
// visible fraction of each minute. Stretching to at least a minute (or 4× the
// cost, whichever is longer) keeps the panel updated without the agent being
// the busiest thing on an idle VPS.
func stretchExpensive(base time.Duration, stage string) time.Duration {
	cost := lastStageMs(stage)
	if cost < 250 {
		return base
	}
	// Four times the measured cost, floored at a minute.
	stretched := time.Duration(cost*4) * time.Millisecond
	if stretched < time.Minute {
		stretched = time.Minute
	}
	if stretched > base {
		return stretched
	}
	return base
}

func (e *SyncEngine) pusher(kind syncKind) func() error {
	switch kind {
	case syncPorts:
		return e.pushPorts
	case syncDocker:
		return e.pushDocker
	case syncSystemd:
		return e.pushSystemd
	case syncProxy:
		return e.pushProxy
	default:
		return e.pushMetrics
	}
}

func (e *SyncEngine) watchdog(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		iv := e.intervals()
		wait := iv.watchdog
		if wait <= 0 {
			wait = 2 * time.Second
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if iv.watchdog <= 0 {
			continue
		}
		e.fpMu.Lock()
		prev := e.fp
		e.fpMu.Unlock()

		// Metrics only. Watching docker/systemd/ports here is what made an
		// idle box look busy — those stages stay on their own intervals and
		// on RequestRefresh after panel actions.
		if prev.metrics != "" {
			metrics, _ := e.reporter.Metrics()
			if fingerprintMetrics(metrics) != prev.metrics {
				_ = e.pushMetrics()
			}
		}
	}
}

// watchdogCostShare is how much of the watchdog interval one stage may spend.
// At 5s that allows 250ms — enough for metrics, ports, proxy and a healthy
// D-Bus systemd read, and far too little for anything that forks processes.
const watchdogCostShare = 0.05

// docker is never watched on the 5s loop, even when it fits the budget. A
// ~150–200ms Engine API pass every five seconds was twelve collections a
// minute and showed up as 10–20% CPU spikes on an idle VPS. The interval
// loop plus RequestRefresh after panel actions are enough for docker.
func affordable(stage string, budgetMs float64) bool {
	if stage == "docker" {
		return false
	}
	cost := lastStageMs(stage)
	return cost == 0 || cost <= budgetMs
}

func (e *SyncEngine) PushAll() {
	// Metrics first and alone so the live graph moves before the heavier
	// snapshots finish — otherwise waking from eco looked like a 5–7s stall.
	_ = e.pushMetrics()

	var wg sync.WaitGroup
	for _, fn := range []func() error{e.pushPorts, e.pushDocker, e.pushSystemd, e.pushProxy} {
		wg.Add(1)
		go func(fn func() error) {
			defer wg.Done()
			_ = fn()
		}(fn)
	}
	wg.Wait()
}

func (e *SyncEngine) pushMetrics() error {
	metrics, err := e.reporter.Metrics()
	if err != nil {
		log.Printf("metrics: %v", err)
	}
	fp := fingerprintMetrics(metrics)
	e.fpMu.Lock()
	e.fp.metrics = fp
	e.fpMu.Unlock()
	return e.send(shared.AgentWSMetrics, func(msg *shared.AgentWSMessage) {
		msg.Metrics = &metrics
	})
}

func (e *SyncEngine) pushPorts() error {
	ports, err := e.reporter.Ports()
	if err != nil {
		log.Printf("ports: %v", err)
	}
	fp := fingerprintPorts(ports)
	e.fpMu.Lock()
	e.fp.ports = fp
	e.fpMu.Unlock()
	return e.send(shared.AgentWSPortsSnapshot, func(msg *shared.AgentWSMessage) {
		msg.Ports = ports
	})
}

func (e *SyncEngine) pushDocker() error {
	docker := e.reporter.Docker()
	fp := fingerprintDocker(docker)
	e.fpMu.Lock()
	e.fp.docker = fp
	e.fpMu.Unlock()
	return e.send(shared.AgentWSDockerSnapshot, func(msg *shared.AgentWSMessage) {
		msg.Docker = &docker
	})
}

func (e *SyncEngine) pushSystemd() error {
	services := e.reporter.Systemd()
	fp := fingerprintSystemd(services)
	e.fpMu.Lock()
	e.fp.systemd = fp
	e.fpMu.Unlock()
	return e.send(shared.AgentWSSystemdSnapshot, func(msg *shared.AgentWSMessage) {
		msg.Services = &services
	})
}

func (e *SyncEngine) pushProxy() error {
	proxy := e.reporter.Proxy()
	fp := fingerprintProxy(proxy)
	e.fpMu.Lock()
	e.fp.proxy = fp
	e.fpMu.Unlock()
	return e.send(shared.AgentWSProxySnapshot, func(msg *shared.AgentWSMessage) {
		msg.Proxy = &proxy
	})
}

// sendBackfill hands the backend samples recorded while it was away. Separate
// from pushMetrics because it carries history, not the current state: it must
// not disturb the change-detection fingerprints that decide whether a live
// snapshot is worth sending.
func (e *SyncEngine) sendBackfill(samples []shared.MetricSample) error {
	if len(samples) == 0 {
		return nil
	}
	return e.send(shared.AgentWSBackfill, func(m *shared.AgentWSMessage) {
		m.Backfill = samples
	})
}

func (e *SyncEngine) send(typ shared.AgentWSMessageType, fill func(*shared.AgentWSMessage)) error {
	msg := shared.AgentWSMessage{
		Type:     typ,
		VPSID:    e.cfg.VPSID,
		AgentVer: AgentVersion,
	}
	fill(&msg)
	out, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	e.mu.RLock()
	done := e.done
	e.mu.RUnlock()

	// Checked before the send rather than alongside it: a select with several
	// ready cases picks at random, so pairing them would sometimes write into a
	// session that has already ended. PushAll runs in its own goroutine and can
	// reach this line well after its session is gone.
	select {
	case <-done:
		return fmt.Errorf("session ended before %s was sent", typ)
	default:
	}

	select {
	case <-done:
		return fmt.Errorf("session ended before %s was sent", typ)
	case e.writeCh <- out:
		return nil
	default:
		return fmt.Errorf("ws write buffer full (%s)", typ)
	}
}

func fingerprintMetrics(m shared.SystemMetrics) string {
	return fmt.Sprintf("cpu:%.0f|mem:%.0f|disk:%d", m.CPUPercent/5, m.MemPercent/5, len(m.Disks))
}

func fingerprintDocker(d shared.DockerState) string {
	s := fmt.Sprintf("avail:%v|err:%s", d.Available, d.Error)
	for _, c := range d.Containers {
		s += fmt.Sprintf("|%s:%s:%d:%d", c.ID, c.State, c.ExitCode, c.RestartCount)
	}
	return s
}

func fingerprintSystemd(svc shared.ServicesState) string {
	s := ""
	for _, u := range svc.Systemd {
		s += fmt.Sprintf("|%s:%s", u.Name, u.ActiveState)
	}
	return s
}

func fingerprintProxy(p shared.ProxyState) string {
	return fmt.Sprintf("%s|r:%v|e:%s", p.Provider, p.Running, p.LastError)
}

func fingerprintPorts(ports []shared.PortInfo) string {
	s := fmt.Sprintf("n:%d", len(ports))
	for _, p := range ports {
		s += fmt.Sprintf("|%d:%s", p.Port, p.ProcessName)
	}
	return s
}
