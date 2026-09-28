package main

import "beacle/shared"

// Collector abstracts the OS layer. The real implementation lives in the
// *_linux.go files; other platforms get a simulated collector used only for
// local development of the panel.
type Collector interface {
	Metrics() (shared.SystemMetrics, error)
	Processes() ([]shared.ProcessInfo, error)
	Ports() ([]shared.PortInfo, error)
	PortDetail(port int) (shared.PortInfo, error)

	Docker() shared.DockerState
	DockerAction(id, action string) error // start | stop | restart | remove
	DockerLogs(id string, tail int) (string, error)
	DockerStats(id string) (shared.ContainerStats, error)
	// DockerExec runs a one-shot shell command inside a container (no TTY).
	DockerExec(id, command string) (shared.DockerExecResult, error)
	// ComposeAction runs a compose lifecycle command: restart | up | down | pull.
	ComposeAction(project, action string) (shared.ComposeActionResult, error)
	// PrunePreview estimates reclaimable space; DockerPrune removes it.
	PrunePreview() (shared.DockerPrunePreview, error)
	DockerPrune(req shared.DockerPruneRequest) (shared.DockerPruneResult, error)

	// KillProcess signals a process by PID ("term" | "kill"). The agent
	// refuses PID 1 and its own PID.
	KillProcess(pid int, signal string) error

	SystemdUnits() ([]shared.SystemdUnit, error)
	SystemdAction(unit, action string) (string, error)
	SystemdLogs(unit string, lines int) (string, error)

	ScreenSessions() ([]shared.ScreenSession, error)
	ScreenStart(req shared.ScreenStartRequest) error
	ScreenStop(name string) error // sends Ctrl+C to the running payload
	// Creating and removing units. Preview renders and verifies without
	// writing anything, so the panel can show the file before it exists.
	PreviewSystemdUnit(spec shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error)
	CreateSystemdUnit(spec shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error)
	DeleteSystemdUnit(name string) error

	ScreenKill(name string) error // removes the session itself
	ScreenLogs(name string) (string, error)

	// Detached jobs with no terminal attached, for things that just need to
	// keep running rather than be watched.
	NohupJobs() ([]shared.NohupJob, error)
	NohupStart(req shared.NohupStartRequest) (shared.NohupJob, error)
	NohupStop(name string) error
	NohupLogs(name string) (string, error)

	ListDir(path string) (shared.FSListing, error)

	Ping(target string) shared.PingResult
}
