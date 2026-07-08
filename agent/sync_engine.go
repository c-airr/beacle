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

	mu          sync.RWMutex
	mode        shared.PowerMode
	modeVersion atomic.Uint32

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
	e.modeVersion.Add(1)
	go e.PushAll()
}

func (e *SyncEngine) RequestRefresh() {
	go e.PushAll()
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
	switch kind {
	case syncPorts:
		return iv.ports
	case syncDocker:
		return iv.docker
	case syncSystemd:
		return iv.systemd
	case syncProxy:
		return iv.proxy
	default:
		return iv.metrics
	}
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

		metrics, _ := e.reporter.Metrics()
		docker := e.reporter.Docker()
		systemd := e.reporter.Systemd()
		proxy := e.reporter.Proxy()
		ports, _ := e.reporter.Ports()

		curMetrics := fingerprintMetrics(metrics)
		curDocker := fingerprintDocker(docker)
		curSystemd := fingerprintSystemd(systemd)
		curProxy := fingerprintProxy(proxy)
		curPorts := fingerprintPorts(ports)

		if prev.metrics != "" && curMetrics != prev.metrics {
			_ = e.pushMetrics()
		}
		if prev.docker != "" && curDocker != prev.docker {
			_ = e.pushDocker()
		}
		if prev.systemd != "" && curSystemd != prev.systemd {
			_ = e.pushSystemd()
		}
		if prev.proxy != "" && curProxy != prev.proxy {
			_ = e.pushProxy()
		}
		if prev.ports != "" && curPorts != prev.ports {
			_ = e.pushPorts()
		}
	}
}

func (e *SyncEngine) PushAll() {
	_ = e.pushMetrics()
	_ = e.pushPorts()
	_ = e.pushDocker()
	_ = e.pushSystemd()
	_ = e.pushProxy()
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
	select {
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
