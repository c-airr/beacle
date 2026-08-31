package main

import (
	"log"
	"os"
	"runtime"
	"time"

	"beacle/shared"
)

// Reporter collects VPS state for WebSocket snapshot frames.
//
// Each collector sits behind a gate, because three callers want the same data
// independently — the interval loop, PushAll on any panel action, and the
// watchdog — and without one they collected it three times at once. The
// freshness windows are a fraction of the fastest interval that asks for each
// stage, so a scheduled collection is never served a cached value while a
// burst of simultaneous requests is served exactly one collection.
type Reporter struct {
	cfg   *Config
	col   Collector
	proxy *ProxyManager

	metricsGate *collectGate[metricsResult]
	portsGate   *collectGate[portsResult]
	dockerGate  *collectGate[shared.DockerState]
	systemdGate *collectGate[shared.ServicesState]
	proxyGate   *collectGate[shared.ProxyState]
}

// Errors travel with the value so a gated call can hand a queued caller the
// same outcome the collection actually had.
type metricsResult struct {
	metrics shared.SystemMetrics
	err     error
}

type portsResult struct {
	ports []shared.PortInfo
	err   error
}

func NewReporter(cfg *Config, col Collector, proxy *ProxyManager) *Reporter {
	return &Reporter{
		cfg:   cfg,
		col:   col,
		proxy: proxy,
		// Metrics drive the live graph on a 3s interval, so its window is short
		// enough never to flatten it.
		metricsGate: newCollectGate[metricsResult](time.Second),
		portsGate:   newCollectGate[portsResult](3 * time.Second),
		// Docker and systemd are the expensive ones and change slowly; anything
		// asking twice within five seconds gets the same answer either way.
		dockerGate:  newCollectGate[shared.DockerState](5 * time.Second),
		systemdGate: newCollectGate[shared.ServicesState](5 * time.Second),
		proxyGate:   newCollectGate[shared.ProxyState](3 * time.Second),
	}
}

func (r *Reporter) RegisterRequest() shared.RegisterRequest {
	hostname, _ := os.Hostname()
	return shared.RegisterRequest{
		VPSID:         r.cfg.VPSID,
		Hostname:      hostname,
		TailscaleName: tailscaleName(),
		TailscaleIP:   tailscaleIPv4(),
		PublicIP:      fetchPublicIP(),
		AgentVersion:  AgentVersion,
		AgentDigest:   selfDigest(),
		Arch:          runtime.GOARCH,
		AgentPort:     0,
		OS:            runtime.GOOS + "/" + runtime.GOARCH,
	}
}

// Every collector is timed here rather than at the push site, because the
// watchdog collects the same data to look for changes and those runs were
// invisible in the timings — which is how a stage costing two seconds could
// run 400 times in 45 minutes without anything showing it.

func (r *Reporter) Metrics() (shared.SystemMetrics, error) {
	res := r.metricsGate.do(func() metricsResult {
		defer track("metrics")()
		m, err := r.col.Metrics()
		return metricsResult{metrics: m, err: err}
	})
	return res.metrics, res.err
}

func (r *Reporter) Ports() ([]shared.PortInfo, error) {
	res := r.portsGate.do(func() portsResult {
		defer track("ports")()
		p, err := r.col.Ports()
		return portsResult{ports: p, err: err}
	})
	return res.ports, res.err
}

func (r *Reporter) Docker() shared.DockerState {
	return r.dockerGate.do(func() shared.DockerState {
		defer track("docker")()
		return r.col.Docker()
	})
}

func (r *Reporter) Systemd() shared.ServicesState {
	return r.systemdGate.do(func() shared.ServicesState {
		defer track("systemd")()
		units, _ := r.col.SystemdUnits()
		screens, _ := r.col.ScreenSessions()
		return shared.ServicesState{
			Systemd: units,
			Screen:  screens,
		}
	})
}

func (r *Reporter) Proxy() shared.ProxyState {
	return r.proxyGate.do(func() shared.ProxyState {
		defer track("proxy")()
		return r.proxy.State()
	})
}

func (r *Reporter) ApplyRegisterAck(ack shared.RegisterResponse) {
	changed := false
	if ack.VPSID != "" && r.cfg.VPSID != ack.VPSID {
		r.cfg.VPSID = ack.VPSID
		changed = true
	}
	if ack.Token != "" && r.cfg.Token != ack.Token {
		r.cfg.Token = ack.Token
		changed = true
	}
	if changed {
		if err := r.cfg.Save(); err != nil {
			log.Printf("warning: could not persist credentials: %v", err)
		}
	}
	if ack.VPSID != "" {
		log.Printf("registered as vps %s", ack.VPSID)
	}
}
