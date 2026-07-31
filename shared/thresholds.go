package shared

// Alerting thresholds shared by backend evaluation and UI display.
const (
	CPUHighPercent     = 85.0
	MemHighPercent     = 90.0
	DiskHighPercent    = 90.0
	HighLoadCPUPercent = 75.0 // marker turns yellow above this

	// OfflineAfterSec: how long the agent WebSocket may stay down before an
	// offline alert fires and the last snapshot is dropped. The VPS status
	// itself flips as soon as the socket goes away — this is only the grace
	// window for alerting, so a short reconnect does not spam alerts.
	// Live sockets are never marked offline regardless of this value.
	OfflineAfterSec  = 45
	DefaultAgentPort = 8931
)
