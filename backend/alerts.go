package main

import (
	"fmt"
	"log"
	"sync"
	"time"

	"beacle/shared"
)

// AlertEngine evaluates incoming reports against thresholds and tracks state
// transitions (a condition fires one alert when it starts, not every report).
type AlertEngine struct {
	mu       sync.Mutex
	store    *Store
	hub      *Hub
	agentHub *AgentHub
	// active["vpsid|type|key"] = true while the condition holds
	active map[string]bool
	// since["vpsid|metric"] = when a threshold was first exceeded, for the
	// sustained-for check.
	since map[string]time.Time
	// previous per-VPS state used for transition detection
	prevContainers map[string]map[string]shared.ContainerInfo // vps -> containerID -> info
	prevServices   map[string]map[string]string               // vps -> unit -> active_state
	// reach caches the Tailscale probe per VPS; see hostReachable.
	reach map[string]reachProbe
}

type reachProbe struct {
	up bool
	at time.Time
}

func NewAlertEngine(store *Store, hub *Hub) *AlertEngine {
	e := &AlertEngine{
		store:          store,
		hub:            hub,
		active:         map[string]bool{},
		since:          map[string]time.Time{},
		prevContainers: map[string]map[string]shared.ContainerInfo{},
		prevServices:   map[string]map[string]string{},
		reach:          map[string]reachProbe{},
	}
	// Alerts outlive the process that raised them. Without adopting the open
	// ones, a restarted backend would neither resolve them when the condition
	// clears — it would not know they exist — nor recognise the condition as
	// already reported, and would raise a second alert beside the first.
	// Anything already resolved is a problem that is over, and older builds
	// kept those rows forever. They are cleared out once, on the way past.
	if n := store.PurgeResolvedAlerts(); n > 0 {
		log.Printf("alerts: removed %d resolved rows left by an earlier build", n)
	}
	for _, a := range store.ListAlerts() {
		if a.Type == shared.AlertServiceDown && !a.Resolved {
			store.ResolveAlert(a.ID)
			continue
		}
		if !a.Resolved {
			e.active[a.VPSID+"|"+string(a.Type)+"|"+a.Key] = true
		}
	}
	return e
}

// reachProbeEvery is how often a VPS that is already known to be down gets
// asked again. Each probe shells out to tailscale, and the answer only decides
// which of two messages an existing alert carries — it is not worth a process
// every half minute for a machine nobody is waiting on.
const reachProbeEvery = 2 * time.Minute

// hostReachable answers "is the machine there, or only the agent gone", from a
// cache. WatchOffline ticks every three seconds; without this it would spawn a
// tailscale process on nearly every tick.
func (e *AlertEngine) hostReachable(id, host string) bool {
	e.mu.Lock()
	c, ok := e.reach[id]
	e.mu.Unlock()
	if ok && time.Since(c.at) < reachProbeEvery {
		return c.up
	}
	up := tailscaleReachable(host)
	e.mu.Lock()
	e.reach[id] = reachProbe{up: up, at: time.Now()}
	e.mu.Unlock()
	return up
}

func (e *AlertEngine) SetAgentHub(h *AgentHub) { e.agentHub = h }

func (e *AlertEngine) fire(vps shared.VPS, t shared.AlertType, sev shared.AlertSeverity, key, msg string) {
	id := vps.ID + "|" + string(t) + "|" + key
	if e.active[id] {
		return
	}
	e.active[id] = true
	a := e.store.AddAlert(shared.Alert{
		VPSID: vps.ID, VPSName: vps.Name, Type: t, Severity: sev, Message: msg, Key: key,
	})
	e.hub.Broadcast(shared.WSAlert, a)
}

// clear marks the condition as no longer holding — and resolves the alerts it
// raised. Forgetting the active flag alone only allowed the alert to fire
// again; the row itself stayed open forever, so a VPS that was unreachable for
// five seconds an hour ago still reads as a problem.
func (e *AlertEngine) clear(vpsID string, t shared.AlertType, key string) {
	if !e.active[vpsID+"|"+string(t)+"|"+key] {
		// Nothing was raised, so there is nothing to resolve. Checked first
		// because clear() is called on every healthy sample of every metric.
		return
	}
	delete(e.active, vpsID+"|"+string(t)+"|"+key)
	for _, a := range e.store.ResolveAlertsFor(vpsID, t, key) {
		e.hub.Broadcast(shared.WSAlert, a)
	}
}

// clearReachability resolves agent_offline / agent_down for a VPS that has a
// live socket again. Unlike clear(), this always asks the store — the status
// may already have been flipped to online by a snapshot before WatchOffline
// ran, which used to skip clear() and leave the row hanging forever.
func (e *AlertEngine) clearReachability(vpsID string) {
	for _, t := range []shared.AlertType{shared.AlertAgentOffline, shared.AlertAgentDown} {
		delete(e.active, vpsID+"|"+string(t)+"|")
		for _, a := range e.store.ResolveAlertsFor(vpsID, t, "") {
			e.hub.Broadcast(shared.WSAlert, a)
		}
	}
	delete(e.reach, vpsID)
}

// sustained reports whether `over` has held continuously for SustainedSeconds.
// The first sample over the threshold only starts the clock, so a momentary
// spike — a build, a backup, a container starting — never raises an alert.
// Dropping below the threshold resets it, so the window has to be cleared in
// one unbroken run.
func (e *AlertEngine) sustained(vpsID, metric string, over bool) bool {
	key := vpsID + "|" + metric
	if !over {
		delete(e.since, key)
		return false
	}
	start, seen := e.since[key]
	if !seen {
		e.since[key] = time.Now()
		return false
	}
	return time.Since(start) >= shared.SustainedSeconds*time.Second
}

// EvaluateSnapshot is called when any agent snapshot frame updates backend state.
func (e *AlertEngine) EvaluateSnapshot(vps shared.VPS, snap *shared.VPSSnapshot) {
	e.mu.Lock()
	defer e.mu.Unlock()

	m := snap.Metrics
	if e.sustained(vps.ID, "cpu", m.CPUPercent >= shared.CPUHighPercent) {
		e.fire(vps, shared.AlertCPUHigh, shared.SeverityWarning, "",
			fmt.Sprintf("CPU above %.0f%% for %ds (now %.0f%%)",
				shared.CPUHighPercent, shared.SustainedSeconds, m.CPUPercent))
	} else if m.CPUPercent < shared.CPUClearPercent {
		e.clear(vps.ID, shared.AlertCPUHigh, "")
	}
	if e.sustained(vps.ID, "mem", m.MemPercent >= shared.MemHighPercent) {
		e.fire(vps, shared.AlertMemHigh, shared.SeverityWarning, "",
			fmt.Sprintf("RAM above %.0f%% for %ds (now %.0f%%)",
				shared.MemHighPercent, shared.SustainedSeconds, m.MemPercent))
	} else if m.MemPercent < shared.MemClearPercent {
		e.clear(vps.ID, shared.AlertMemHigh, "")
	}
	for _, d := range m.Disks {
		if d.UsedPercent >= shared.DiskHighPercent {
			e.fire(vps, shared.AlertDiskHigh, shared.SeverityWarning, d.Mount,
				fmt.Sprintf("Disk %s at %.0f%%", d.Mount, d.UsedPercent))
		} else if d.UsedPercent < shared.DiskClearPercent {
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

	// systemd: services do not trigger alerts / notifications. Clear any legacy alerts.
	for _, a := range e.store.ResolveAlertsFor(vps.ID, shared.AlertServiceDown, "") {
		e.hub.Broadcast(shared.WSAlert, a)
	}

	// Proxy errors
	if snap.Proxy.Provider != shared.ProxyProviderNone {
		// A stopped proxy is deliberately not an alert. Detection keys off the
		// binary being installed, so a box with Caddy sitting unused — or one
		// where the proxy is simply not meant to run — would page the user
		// forever about a service they never asked to have running.
		e.clear(vps.ID, shared.AlertProxyError, "down")
		if snap.Proxy.LastError != "" {
			e.fire(vps, shared.AlertProxyError, shared.SeverityWarning, "err", snap.Proxy.LastError)
		} else {
			e.clear(vps.ID, shared.AlertProxyError, "err")
		}
	}
}

// WatchOffline keeps the VPS status tied to the agent WebSocket: a live socket
// means online even if a metrics tick was delayed (eco/sleep mode, slow docker
// collect), and a missing socket means offline. Only the *alert* waits out the
// grace window, so a reconnect after a network blip never raises one.
func (e *AlertEngine) WatchOffline() {
	for range time.Tick(3 * time.Second) {
		for _, v := range e.store.ListVPS() {
			if v.Status == shared.VPSPending {
				continue
			}
			live := e.agentHub != nil && e.agentHub.Connected(v.ID)
			if live {
				// A snapshot/heartbeat often flips Status to online the moment
				// the socket returns — before this tick runs. Clearing used to
				// gate on "still Offline/AgentDown", so the alert stayed open
				// forever while the panel already showed a healthy agent.
				if v.Status == shared.VPSOffline || v.Status == shared.VPSAgentDown {
					e.store.UpdateVPS(v.ID, func(en *VPSEntry) {
						en.VPS.Status = shared.VPSOnline
						en.VPS.LastSeen = time.Now().UTC()
					})
					e.hub.Broadcast(shared.WSVPSList, e.store.ListVPS())
				}
				e.mu.Lock()
				e.clearReachability(v.ID)
				e.mu.Unlock()
				continue
			}
			if v.Status != shared.VPSOffline && v.Status != shared.VPSAgentDown {
				e.store.UpdateVPS(v.ID, func(en *VPSEntry) {
					en.VPS.Status = shared.VPSOffline
				})
				e.hub.Broadcast(shared.WSVPSList, e.store.ListVPS())
			}
			// Socket gone for longer than the grace window: this is a real
			// outage, not a reconnect. Which outage it is decides what the user
			// should go and do, so ask the tailnet before saying the box died —
			// a crashed agent on a healthy server is a restart, not a rescue.
			if time.Since(v.LastSeen) > shared.OfflineAfterSec*time.Second {
				e.store.ClearSnapshot(v.ID)
				hostUp := e.hostReachable(v.ID, v.Host)

				want := shared.VPSOffline
				if hostUp {
					want = shared.VPSAgentDown
				}
				if v.Status != want {
					e.store.UpdateVPS(v.ID, func(en *VPSEntry) { en.VPS.Status = want })
					e.hub.Broadcast(shared.WSVPSList, e.store.ListVPS())
				}

				e.mu.Lock()
				if hostUp {
					e.clear(v.ID, shared.AlertAgentOffline, "")
					e.fire(v, shared.AlertAgentDown, shared.SeverityCritical, "",
						"Agent is not responding — the VPS itself answers on Tailscale")
				} else {
					e.clear(v.ID, shared.AlertAgentDown, "")
					e.fire(v, shared.AlertAgentOffline, shared.SeverityCritical, "",
						"VPS offline — no answer on its Tailscale address")
				}
				e.mu.Unlock()
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
