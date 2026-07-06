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
	DockerAction(id, action string) error // start | stop | restart
	DockerLogs(id string, tail int) (string, error)
	DockerStats(id string) (shared.ContainerStats, error)

	SystemdUnits() ([]shared.SystemdUnit, error)
	SystemdAction(unit, action string) (string, error)
	SystemdLogs(unit string, lines int) (string, error)
	ScreenSessions() ([]shared.ScreenSession, error)

	Ping(target string) shared.PingResult
}
