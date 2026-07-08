package main

import (
	"fmt"
	"sync"
	"time"

	"beacle/shared"
)

// AlertEngine evaluates incoming reports against thresholds and tracks state
// transitions (a condition fires one alert when it starts, not every report).
type AlertEngine struct {
	mu    sync.Mutex
	store *Store
	hub   *Hub
	// active["vpsid|type|key"] = true while the condition holds
	active map[string]bool
	// previous per-VPS state used for transition detection
	prevContainers map[string]map[string]shared.ContainerInfo // vps -> containerID -> info
	prevServices   map[string]map[string]string               // vps -> unit -> active_state
}

func NewAlertEngine(store *Store, hub *Hub) *AlertEngine {
	return &AlertEngine{
		store:          store,
		hub:            hub,
		active:         map[string]bool{},
		prevContainers: map[string]map[string]shared.ContainerInfo{},
		prevServices:   map[string]map[string]string{},
	}
}

func (e *AlertEngine) fire(vps shared.VPS, t shared.AlertType, sev shared.AlertSeverity, key, msg string) {
	id := vps.ID + "|" + string(t) + "|" + key
	if e.active[id] {
		return
	}
	e.active[id] = true
	a := e.store.AddAlert(shared.Alert{VPSID: vps.ID, VPSName: vps.Name, Type: t, Severity: sev, Message: msg})
	e.hub.Broadcast(shared.WSAlert, a)
}

func (e *AlertEngine) clear(vpsID string, t shared.AlertType, key string) {
	delete(e.active, vpsID+"|"+string(t)+"|"+key)
}

// EvaluateSnapshot is called when any agent snapshot frame updates backend state.
func (e *AlertEngine) EvaluateSnapshot(vps shared.VPS, snap *shared.VPSSnapshot) {
	e.mu.Lock()
	defer e.mu.Unlock()

	m := snap.Metrics
	if m.CPUPercent >= shared.CPUHighPercent {
		e.fire(vps, shared.AlertCPUHigh, shared.SeverityWarning, "",
			fmt.Sprintf("CPU usage %.0f%% (threshold %.0f%%)", m.CPUPercent, shared.CPUHighPercent))
	} else {
		e.clear(vps.ID, shared.AlertCPUHigh, "")
	}
	if m.MemPercent >= shared.MemHighPercent {
		e.fire(vps, shared.AlertMemHigh, shared.SeverityWarning, "",
			fmt.Sprintf("RAM usage %.0f%%", m.MemPercent))
	} else {
		e.clear(vps.ID, shared.AlertMemHigh, "")
	}
	for _, d := range m.Disks {
		if d.UsedPercent >= shared.DiskHighPercent {
			e.fire(vps, shared.AlertDiskHigh, shared.SeverityWarning, d.Mount,
				fmt.Sprintf("Disk %s at %.0f%%", d.Mount, d.UsedPercent))
		} else {
			e.clear(vps.ID, shared.AlertDiskHigh, d.Mount)
		}
	}

	// Docker: exited with non-zero code, or restart count increased.
	prev := e.prevContainers[vps.ID]
	cur := map[string]shared.ContainerInfo{}
	for _, c := range snap.Docker.Containers {
		cur[c.ID] = c
		if prev != nil {
			if p, ok := prev[c.ID]; ok {
				if p.State == "running" && c.State == "exited" && c.ExitCode != 0 {
					e.fire(vps, shared.AlertDockerCrash, shared.SeverityCritical, c.ID,
						fmt.Sprintf("Container %s crashed (exit %d)", c.Name, c.ExitCode))
				}
				if c.RestartCount > p.RestartCount {
					e.fire(vps, shared.AlertDockerCrash, shared.SeverityWarning, c.ID+"-restart",
						fmt.Sprintf("Container %s restarted (count %d)", c.Name, c.RestartCount))
				}
				if c.State == "running" {
					e.clear(vps.ID, shared.AlertDockerCrash, c.ID)
					e.clear(vps.ID, shared.AlertDockerCrash, c.ID+"-restart")
				}
			}
		}
	}
	e.prevContainers[vps.ID] = cur

	// systemd: unit transitioned active -> failed
	prevSvc := e.prevServices[vps.ID]
	curSvc := map[string]string{}
	for _, u := range snap.Services.Systemd {
		curSvc[u.Name] = u.ActiveState
		if prevSvc != nil {
			if was, ok := prevSvc[u.Name]; ok && was == "active" && u.ActiveState == "failed" {
				e.fire(vps, shared.AlertServiceDown, shared.SeverityCritical, u.Name,
					fmt.Sprintf("Service %s failed", u.Name))
			}
			if u.ActiveState == "active" {
				e.clear(vps.ID, shared.AlertServiceDown, u.Name)
			}
		}
	}
	e.prevServices[vps.ID] = curSvc

	// Proxy errors
	if snap.Proxy.Provider != shared.ProxyProviderNone {
		if !snap.Proxy.Running {
			e.fire(vps, shared.AlertProxyError, shared.SeverityCritical, "down",
				fmt.Sprintf("Reverse proxy (%s) is not running", snap.Proxy.Provider))
		} else {
			e.clear(vps.ID, shared.AlertProxyError, "down")
		}
		if snap.Proxy.LastError != "" {
			e.fire(vps, shared.AlertProxyError, shared.SeverityWarning, "err", snap.Proxy.LastError)
		} else {
			e.clear(vps.ID, shared.AlertProxyError, "err")
		}
	}
}

// WatchOffline marks VPSes offline when reports stop arriving.
func (e *AlertEngine) WatchOffline() {
	for range time.Tick(5 * time.Second) {
		for _, v := range e.store.ListVPS() {
			if v.Status == shared.VPSPending || v.Status == shared.VPSOffline {
				continue
			}
			if time.Since(v.LastSeen) > shared.OfflineAfterSec*time.Second {
				updated := e.store.UpdateVPS(v.ID, func(en *VPSEntry) {
					en.VPS.Status = shared.VPSOffline
				})
				e.store.ClearSnapshot(v.ID)
				e.mu.Lock()
				e.fire(updated.VPS, shared.AlertAgentOffline, shared.SeverityCritical, "",
					"Agent stopped reporting - VPS offline")
				e.mu.Unlock()
				e.hub.Broadcast(shared.WSVPSList, e.store.ListVPS())
			}
		}
	}
}

func statusFor(m shared.SystemMetrics) shared.VPSStatus {
	if m.CPUPercent >= shared.HighLoadCPUPercent || m.MemPercent >= shared.MemHighPercent {
		return shared.VPSHighLoad
	}
	return shared.VPSOnline
}
