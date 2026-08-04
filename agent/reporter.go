package main

import (
	"log"
	"os"
	"runtime"

	"beacle/shared"
)

// Reporter collects VPS state for WebSocket snapshot frames.
type Reporter struct {
	cfg   *Config
	col   Collector
	proxy *ProxyManager
}

func NewReporter(cfg *Config, col Collector, proxy *ProxyManager) *Reporter {
	return &Reporter{cfg: cfg, col: col, proxy: proxy}
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
		AgentPort:     0,
		OS:            runtime.GOOS + "/" + runtime.GOARCH,
	}
}

// Every collector is timed here rather than at the push site, because the
// watchdog collects the same data to look for changes and those runs were
// invisible in the timings — which is how a stage costing two seconds could
// run 400 times in 45 minutes without anything showing it.

func (r *Reporter) Metrics() (shared.SystemMetrics, error) {
	defer track("metrics")()
	return r.col.Metrics()
}

func (r *Reporter) Ports() ([]shared.PortInfo, error) {
	defer track("ports")()
	return r.col.Ports()
}

func (r *Reporter) Docker() shared.DockerState {
	defer track("docker")()
	return r.col.Docker()
}

func (r *Reporter) Systemd() shared.ServicesState {
	defer track("systemd")()
	units, _ := r.col.SystemdUnits()
	screens, _ := r.col.ScreenSessions()
	return shared.ServicesState{
		Systemd: units,
		Screen:  screens,
	}
}

func (r *Reporter) Proxy() shared.ProxyState {
	defer track("proxy")()
	return r.proxy.State()
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
