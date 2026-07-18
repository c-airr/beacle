//go:build !linux

package main

import (
	"fmt"
	"math"
	"math/rand"
	"os"
	"runtime"
	"sync"
	"time"

	"beacle/shared"
)

// devCollector simulates a Linux VPS so the whole stack can be developed and
// demoed on Windows/macOS. The production agent is Linux-only.
type devCollector struct {
	mu      sync.Mutex
	start   time.Time
	rng     *rand.Rand
	dockerC []shared.ContainerInfo
}

func newCollector(cfg *Config) Collector {
	c := &devCollector{start: time.Now(), rng: rand.New(rand.NewSource(time.Now().UnixNano()))}
	mk := func(name, image, state string, restart int, pub int) shared.ContainerInfo {
		return shared.ContainerInfo{
			ID: randomID() + randomID(), Name: name, Image: image, State: state,
			Status: map[string]string{"running": "Up 2 hours", "exited": "Exited (0) 1 hour ago"}[state],
			CreatedAt: time.Now().Add(-24 * time.Hour), RestartCount: restart,
			Ports: []shared.ContainerPort{{PrivatePort: 80, PublicPort: pub, Protocol: "tcp", IP: "0.0.0.0"}},
			ComposeProject: "demo-stack", ComposeService: name,
		}
	}
	c.dockerC = []shared.ContainerInfo{
		mk("web", "nginx:alpine", "running", 0, 8080),
		mk("api", "node:20-alpine", "running", 1, 3000),
		mk("db", "postgres:16", "running", 0, 5432),
		mk("worker", "redis:7", "exited", 2, 6379),
	}
	return c
}

func (c *devCollector) wave(base, amp, period float64) float64 {
	t := time.Since(c.start).Seconds()
	v := base + amp*math.Sin(t/period) + c.rng.Float64()*5
	return math.Max(0, math.Min(100, v))
}

func (c *devCollector) Metrics() (shared.SystemMetrics, error) {
	host, _ := os.Hostname()
	cpu := c.wave(35, 25, 60)
	mem := c.wave(55, 15, 90)
	total := uint64(8 * 1 << 30)
	used := uint64(float64(total) * mem / 100)
	cached := uint64(float64(1200) * float64(1<<20))
	cores := runtime.NumCPU()
	perCore := make([]float64, cores)
	for i := range perCore {
		perCore[i] = math.Max(0, math.Min(100, cpu+(c.rng.Float64()-0.5)*20))
	}
	return shared.SystemMetrics{
		Hostname: host, OS: "Beacle Dev Simulator (" + runtime.GOOS + ")",
		Kernel: "6.8.0-sim", Arch: runtime.GOARCH,
		CPUPercent: cpu, CPUCores: cores, CPUModel: "Simulated vCPU", CPUPerCore: perCore,
		MemTotalBytes: total, MemUsedBytes: used, MemPercent: mem,
		MemCachedBytes: cached, MemUsedCachedBytes: used + cached,
		MemPercentCached: float64(used+cached) / float64(total) * 100,
		SwapTotal: 2 << 30, SwapUsed: 256 << 20,
		Disks: []shared.DiskUsage{
			{Mount: "/", Filesystem: "ext4", TotalBytes: 80 << 30, UsedBytes: 34 << 30, UsedPercent: 42.5},
			{Mount: "/data", Filesystem: "ext4", TotalBytes: 200 << 30, UsedBytes: 150 << 30, UsedPercent: 75},
		},
		UptimeSeconds: uint64(time.Since(c.start).Seconds()) + 86400*12,
		Load1: cpu / 25, Load5: cpu / 30, Load15: cpu / 40,
		Network: []shared.NetworkStats{{
			Interface: "eth0", RxBytes: 123 << 30, TxBytes: 45 << 30,
			RxPerSec: uint64(c.rng.Intn(2 << 20)), TxPerSec: uint64(c.rng.Intn(1 << 20)),
		}},
		CollectedAt: time.Now().UTC(),
	}, nil
}

func (c *devCollector) Processes() ([]shared.ProcessInfo, error) {
	names := []string{"nginx", "node", "postgres", "redis-server", "sshd", "systemd", "caddy", "beacle-agent"}
	var out []shared.ProcessInfo
	for i, n := range names {
		out = append(out, shared.ProcessInfo{
			PID: 100 + i*13, Name: n, User: "root",
			CPUPercent: c.rng.Float64() * 20, MemPercent: c.rng.Float64() * 10,
			MemBytes: uint64(c.rng.Intn(500)) << 20, Command: "/usr/bin/" + n, State: "S",
		})
	}
	return out, nil
}

func (c *devCollector) Ports() ([]shared.PortInfo, error) {
	return []shared.PortInfo{
		{Port: 22, Protocol: "tcp", ListenAddr: "0.0.0.0", PID: 812, ProcessName: "sshd", CommandLine: "/usr/sbin/sshd -D"},
		{Port: 80, Protocol: "tcp", ListenAddr: "0.0.0.0", PID: 913, ProcessName: "caddy", CommandLine: "/usr/bin/caddy run"},
		{Port: 443, Protocol: "tcp", ListenAddr: "0.0.0.0", PID: 913, ProcessName: "caddy", CommandLine: "/usr/bin/caddy run"},
		{Port: 3000, Protocol: "tcp", ListenAddr: "127.0.0.1", PID: 1044, ProcessName: "node", CommandLine: "node /srv/api/index.js"},
		{Port: 5432, Protocol: "tcp", ListenAddr: "127.0.0.1", PID: 1102, ProcessName: "postgres", CommandLine: "/usr/lib/postgresql/16/bin/postgres"},
		{Port: 8931, Protocol: "tcp", ListenAddr: "0.0.0.0", PID: os.Getpid(), ProcessName: "beacle-agent", CommandLine: "beacle-agent -config config.json"},
	}, nil
}

func (c *devCollector) PortDetail(port int) (shared.PortInfo, error) {
	ports, _ := c.Ports()
	for _, p := range ports {
		if p.Port == port {
			p.Healthy = true
			p.HealthDetail = "tcp connect ok (simulated)"
			return p, nil
		}
	}
	return shared.PortInfo{Port: port, Protocol: "tcp", HealthDetail: "no listener on this port"}, nil
}

func (c *devCollector) Docker() shared.DockerState {
	c.mu.Lock()
	defer c.mu.Unlock()
	st := shared.DockerState{Available: true, Version: "27.0-sim"}
	st.Containers = append(st.Containers, c.dockerC...)
	for _, ci := range c.dockerC {
		if ci.State != "running" {
			continue
		}
		st.Stats = append(st.Stats, shared.ContainerStats{
			ID: ci.ID, Name: ci.Name, CPUPercent: c.rng.Float64() * 30,
			MemUsage: uint64(c.rng.Intn(400)) << 20, MemLimit: 2 << 30,
			MemPercent: c.rng.Float64() * 20, PIDs: 5 + c.rng.Intn(20),
			NetRxBytes: uint64(c.rng.Intn(1 << 30)), NetTxBytes: uint64(c.rng.Intn(1 << 30)),
			CollectedAt: time.Now().UTC().Format(time.RFC3339),
		})
	}
	st.Images = []shared.ImageInfo{
		{ID: "sha256:aaa", Tags: []string{"nginx:alpine"}, SizeBytes: 43 << 20, CreatedAt: time.Now().Add(-100 * time.Hour).Unix()},
		{ID: "sha256:bbb", Tags: []string{"postgres:16"}, SizeBytes: 420 << 20, CreatedAt: time.Now().Add(-300 * time.Hour).Unix()},
		{ID: "sha256:ccc", Tags: []string{"node:20-alpine"}, SizeBytes: 180 << 20, CreatedAt: time.Now().Add(-50 * time.Hour).Unix()},
	}
	st.Compose = []shared.ComposeProject{{
		Name: "demo-stack", WorkingDir: "/srv/demo", ConfigFile: "/srv/demo/docker-compose.yml",
		Services: []string{"api", "db", "web", "worker"}, Running: 3, Total: 4,
	}}
	return st
}

func (c *devCollector) DockerAction(id, action string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := range c.dockerC {
		if c.dockerC[i].ID == id {
			switch action {
			case "start", "restart":
				c.dockerC[i].State = "running"
				c.dockerC[i].Status = "Up 1 second"
				if action == "restart" {
					c.dockerC[i].RestartCount++
				}
			case "stop":
				c.dockerC[i].State = "exited"
				c.dockerC[i].Status = "Exited (0) 1 second ago"
			default:
				return fmt.Errorf("unknown action %q", action)
			}
			return nil
		}
	}
	return fmt.Errorf("container not found")
}

func (c *devCollector) DockerLogs(id string, tail int) (string, error) {
	var s string
	for i := 0; i < 20; i++ {
		s += fmt.Sprintf("%s [info] simulated log line %d for %s\n",
			time.Now().Add(-time.Duration(20-i)*time.Minute).Format(time.RFC3339), i+1, id[:8])
	}
	return s, nil
}

func (c *devCollector) DockerStats(id string) (shared.ContainerStats, error) {
	return shared.ContainerStats{
		ID: id, Name: "sim", CPUPercent: c.rng.Float64() * 40,
		MemUsage: 200 << 20, MemLimit: 2 << 30, MemPercent: 9.7, PIDs: 12,
		CollectedAt: time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (c *devCollector) SystemdUnits() ([]shared.SystemdUnit, error) {
	return []shared.SystemdUnit{
		{Name: "caddy.service", Description: "Caddy web server", LoadState: "loaded", ActiveState: "active", SubState: "running", Enabled: "enabled"},
		{Name: "docker.service", Description: "Docker Application Container Engine", LoadState: "loaded", ActiveState: "active", SubState: "running", Enabled: "enabled"},
		{Name: "ssh.service", Description: "OpenBSD Secure Shell server", LoadState: "loaded", ActiveState: "active", SubState: "running", Enabled: "enabled"},
		{Name: "beacle-agent.service", Description: "Beacle VPS Agent", LoadState: "loaded", ActiveState: "active", SubState: "running", Enabled: "enabled"},
		{Name: "cron.service", Description: "Regular background program processing daemon", LoadState: "loaded", ActiveState: "active", SubState: "running", Enabled: "enabled"},
		{Name: "fail2ban.service", Description: "Fail2Ban Service", LoadState: "loaded", ActiveState: "inactive", SubState: "dead", Enabled: "disabled"},
	}, nil
}

func (c *devCollector) SystemdAction(unit, action string) (string, error) {
	switch action {
	case "start", "restart":
		return "active", nil
	case "stop":
		return "inactive", nil
	}
	return "", fmt.Errorf("unknown action %q", action)
}

func (c *devCollector) SystemdLogs(unit string, lines int) (string, error) {
	var s string
	for i := 0; i < 15; i++ {
		s += fmt.Sprintf("%s host %s[123]: simulated journal line %d\n",
			time.Now().Add(-time.Duration(15-i)*time.Minute).Format("2006-01-02T15:04:05-0700"), unit, i+1)
	}
	return s, nil
}

func (c *devCollector) ScreenSessions() ([]shared.ScreenSession, error) {
	return []shared.ScreenSession{
		{PID: 4211, Name: "minecraft", Attached: false, Created: "07/01/2026 10:22:01 AM"},
		{PID: 5100, Name: "botrunner", Attached: true, Created: "07/03/2026 08:12:44 PM"},
	}, nil
}

func (c *devCollector) Ping(target string) shared.PingResult {
	return shared.PingResult{
		Target: target, LatencyMs: 5 + c.rng.Float64()*40,
		PacketLoss: 0, Reachable: true,
	}
}
