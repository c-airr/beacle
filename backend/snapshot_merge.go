package main

import (
	"time"

	"beacle/shared"
)

func mergeSnapshot(store *Store, hub *Hub, alerts *AlertEngine, entry *VPSEntry, agentVer string, merge func(*shared.VPSSnapshot)) {
	updated := store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.LastSeen = time.Now().UTC()
		if agentVer != "" {
			e.VPS.AgentVer = agentVer
		}
	})

	snap := store.GetSnapshot(entry.VPS.ID)
	if snap == nil {
		snap = &shared.VPSSnapshot{VPS: updated.VPS}
	}
	copy := *snap
	copy.VPS = updated.VPS
	merge(&copy)
	if copy.Metrics.Hostname != "" || copy.Metrics.CPUPercent > 0 {
		copy.VPS.Status = statusFor(copy.Metrics)
	}
	copy.Updated = time.Now().UTC()
	store.SetSnapshot(&copy)

	alerts.EvaluateSnapshot(updated.VPS, &copy)
	hub.Broadcast(shared.WSVPSUpdate, &copy)
}
