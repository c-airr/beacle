package main

import (
	"time"

	"beacle/shared"
)

func mergeSnapshot(store *Store, hub *Hub, alerts *AlertEngine, history *History, entry *VPSEntry, agentVer string, merge func(*shared.VPSSnapshot)) {
	snap := store.GetSnapshot(entry.VPS.ID)
	copy := shared.VPSSnapshot{}
	if snap != nil {
		copy = *snap
	}
	merge(&copy)

	// A frame is proof of life, so the registry follows the snapshot instead of
	// carrying its own idea of the status: the two used to disagree, and the UI
	// (which overwrites its list entry from every snapshot) flickered between
	// them whenever a full list broadcast landed.
	status := shared.VPSOnline
	if copy.Metrics.Hostname != "" || copy.Metrics.CPUPercent > 0 {
		status = statusFor(copy.Metrics)
	}
	updated := store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.LastSeen = time.Now().UTC()
		if agentVer != "" {
			e.VPS.AgentVer = agentVer
		}
		if e.VPS.Status != shared.VPSPending {
			e.VPS.Status = status
		}
	})
	if updated == nil {
		return // deleted while the frame was in flight
	}

	copy.VPS = updated.VPS
	copy.Updated = time.Now().UTC()
	store.SetSnapshot(&copy)

	alerts.EvaluateSnapshot(updated.VPS, &copy)

	// Only metrics frames carry the numbers worth charting; a docker or ports
	// frame would record a row of zeroes and put a false trough in the graph.
	if history != nil && copy.Metrics.CollectedAt.After(time.Time{}) {
		history.Record(updated.VPS.ID, SampleFrom(&copy))
	}

	hub.Broadcast(shared.WSVPSUpdate, &copy)
}
