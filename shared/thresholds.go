package shared

// Alerting thresholds shared by backend evaluation and UI display.
const (
	CPUHighPercent     = 85.0
	MemHighPercent     = 90.0
	DiskHighPercent    = 90.0
	HighLoadCPUPercent = 75.0 // marker turns yellow above this

	// OfflineAfterSec: agent may report metrics as slowly as 60 s in sleep mode.
	OfflineAfterSec  = 90
	DefaultAgentPort = 8931
)
