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
		AgentVersion:  AgentVersion,
		AgentPort:     0,
		OS:            runtime.GOOS + "/" + runtime.GOARCH,
	}
}

func (r *Reporter) Metrics() (shared.SystemMetrics, error) {
	return r.col.Metrics()
}

func (r *Reporter) Ports() ([]shared.PortInfo, error) {
	return r.col.Ports()
}

func (r *Reporter) Docker() shared.DockerState {
	return r.col.Docker()
}

func (r *Reporter) Systemd() shared.ServicesState {
	units, _ := r.col.SystemdUnits()
	screens, _ := r.col.ScreenSessions()
	return shared.ServicesState{
		Systemd: units,
		Screen:  screens,
	}
}

func (r *Reporter) Proxy() shared.ProxyState {
	return r.proxy.State()
}

func (r *Reporter) ApplyRegisterAck(ack shared.RegisterResponse) {
	if ack.VPSID != "" {
		r.cfg.VPSID = ack.VPSID
	}
	if ack.Token != "" {
		r.cfg.Token = ack.Token
		if err := r.cfg.Save(); err != nil {
			log.Printf("warning: could not persist credentials: %v", err)
		}
		log.Printf("registered as vps %s", ack.VPSID)
	}
}
