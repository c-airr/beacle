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

	// SystemLogFiles lists readable system logs; SystemLogs tails one with
	// an optional case-insensitive grep filter.
	SystemLogFiles() ([]shared.SystemLogFile, error)
	SystemLogs(id string, tail int, grep string) (string, error)

	// OSUpdates lists pending system package updates; OSUpdateApply starts a
	// background upgrade; OSUpdateStatus reports on the running/last job.
	OSUpdates() (shared.OSUpdates, error)
	OSUpdateApply() error
	OSUpdateStatus() (shared.OSUpdateJob, error)

	// CronState bundles root's crontab (editable), system cron files and
	// systemd timers (read-only). Mutations only touch root's crontab.
	CronState() (shared.CronState, error)
	CronCreate(spec shared.CronEntrySpec) (shared.CronEntry, error)
	CronUpdate(id string, spec shared.CronEntrySpec) error
	CronDelete(id string) error

	// Firewall across ufw/firewalld/iptables (nftables is read-only), with
	// an SSH guard: protected ports can never be denied to the world, and
	// deleting an allow that covers them needs force.
	FirewallStatus() (shared.FirewallStatus, error)
	FirewallDryRun(req shared.FirewallDryRunRequest) (shared.FirewallDryRun, error)
	FirewallAllow(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error)
	FirewallDeny(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error)
	FirewallDelete(req shared.FirewallDeleteRequest) (shared.FirewallMutation, error)

	// Reboot snapshots sessions into a manifest when asked and reboots the
	// host; Poweroff halts it. RestoreStatus reports the last boot restore.
	Reboot(restore bool) (shared.RebootResult, error)
	Poweroff() error
	RestoreStatus() (shared.RestoreResult, error)

	// Watchdog: fleet supervision from the inside while the backend tunnel
	// is down. Config is pushed by the backend and persisted locally.
	SetWatchdogConfig(cfg shared.WatchdogConfig) error
	SendWatchdogMessage(msg shared.WebhookMessage) error
	WatchdogStatus() (shared.WatchdogStatus, error)

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
