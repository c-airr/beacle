//go:build !linux

package main

import (
	"fmt"
	"math"
	"math/rand"
	"os"
	"runtime"
	"strings"
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
			Status:    map[string]string{"running": "Up 2 hours", "exited": "Exited (0) 1 hour ago"}[state],
			CreatedAt: time.Now().Add(-24 * time.Hour), RestartCount: restart,
			Ports:          []shared.ContainerPort{{PrivatePort: 80, PublicPort: pub, Protocol: "tcp", IP: "0.0.0.0"}},
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
		SwapTotal:        2 << 30, SwapUsed: 256 << 20,
		Disks: []shared.DiskUsage{
			{Mount: "/", Filesystem: "ext4", TotalBytes: 80 << 30, UsedBytes: 34 << 30, UsedPercent: 42.5},
			{Mount: "/data", Filesystem: "ext4", TotalBytes: 200 << 30, UsedBytes: 150 << 30, UsedPercent: 75},
		},
		UptimeSeconds: uint64(time.Since(c.start).Seconds()) + 86400*12,
		Load1:         cpu / 25, Load5: cpu / 30, Load15: cpu / 40,
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
	st.Volumes = []shared.DockerVolume{
		{Name: "demo-stack_pgdata", Driver: "local", Mountpoint: "/var/lib/docker/volumes/demo-stack_pgdata/_data", Scope: "local"},
		{Name: "caddy_data", Driver: "local", Mountpoint: "/var/lib/docker/volumes/caddy_data/_data", Scope: "local"},
	}
	st.Networks = []shared.DockerNetwork{
		{ID: "bridge", Name: "bridge", Driver: "bridge", Scope: "local", Containers: 2},
		{ID: "demo", Name: "demo-stack_default", Driver: "bridge", Scope: "local", Containers: 4},
	}
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
			case "remove", "rm":
				c.dockerC = append(c.dockerC[:i], c.dockerC[i+1:]...)
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

func (c *devCollector) DockerExec(id, command string) (shared.DockerExecResult, error) {
	if strings.TrimSpace(command) == "" {
		return shared.DockerExecResult{}, fmt.Errorf("command is required")
	}
	short := id
	if len(short) > 12 {
		short = short[:12]
	}
	return shared.DockerExecResult{
		Output:   fmt.Sprintf("simulated output of %q in container %s\n", command, short),
		ExitCode: 0,
	}, nil
}

func (c *devCollector) ComposeAction(project, action string) (shared.ComposeActionResult, error) {
	switch action {
	case "restart", "up", "down", "pull":
	default:
		return shared.ComposeActionResult{}, fmt.Errorf("unknown compose action %q", action)
	}
	return shared.ComposeActionResult{
		Output: fmt.Sprintf("simulated compose %s for project %s\n", action, project),
	}, nil
}

func (c *devCollector) PrunePreview() (shared.DockerPrunePreview, error) {
	return shared.DockerPrunePreview{
		DanglingImages: 3, DanglingBytes: 890 << 20,
		UnusedVolumes: 2, UnusedVolumesBytes: 120 << 20,
	}, nil
}

func (c *devCollector) DockerPrune(req shared.DockerPruneRequest) (shared.DockerPruneResult, error) {
	if !req.Images && !req.Volumes && !req.Builder {
		return shared.DockerPruneResult{}, fmt.Errorf("nothing selected")
	}
	res := shared.DockerPruneResult{}
	if req.Images {
		res.ImagesDeleted = 3
		res.SpaceReclaimed += 890 << 20
	}
	if req.Volumes {
		res.VolumesDeleted = 2
		res.SpaceReclaimed += 120 << 20
	}
	return res, nil
}

func (c *devCollector) KillProcess(pid int, signal string) error {
	if pid <= 1 {
		return fmt.Errorf("refusing to signal PID %d", pid)
	}
	switch signal {
	case "", "term", "kill":
		return nil
	default:
		return fmt.Errorf("unknown signal %q (want term or kill)", signal)
	}
}

func (c *devCollector) SystemLogFiles() ([]shared.SystemLogFile, error) {
	return []shared.SystemLogFile{
		{ID: "syslog", Label: "System log", Path: "/var/log/syslog"},
		{ID: "auth", Label: "Auth log", Path: "/var/log/auth.log"},
		{ID: "dmesg", Label: "Kernel ring buffer", Path: "dmesg"},
		{ID: "nginx:access.log", Label: "Nginx / access.log", Path: "/var/log/nginx/access.log"},
	}, nil
}

func (c *devCollector) SystemLogs(id string, tail int, grep string) (string, error) {
	if tail <= 0 {
		tail = 400
	}
	var sb strings.Builder
	for i := 0; i < 30; i++ {
		fmt.Fprintf(&sb, "%s host sim[%d]: simulated %s line %d\n",
			time.Now().Add(-time.Duration(30-i)*time.Minute).Format(time.RFC3339), 1000+i, id, i+1)
	}
	out := sb.String()
	if g := strings.TrimSpace(grep); g != "" {
		var kept []string
		for _, l := range strings.Split(out, "\n") {
			if strings.Contains(strings.ToLower(l), strings.ToLower(g)) {
				kept = append(kept, l)
			}
		}
		out = strings.Join(kept, "\n")
	}
	return out, nil
}

var devUpdateJob = shared.OSUpdateJob{}

func (c *devCollector) OSUpdates() (shared.OSUpdates, error) {
	return shared.OSUpdates{
		Manager: "apt",
		Packages: []shared.OSPackage{
			{Name: "openssl", Current: "3.0.2-0ubuntu1.10", Latest: "3.0.2-0ubuntu1.12", Security: true},
			{Name: "curl", Current: "7.81.0-1", Latest: "7.81.0-1ubuntu1.15", Security: true},
			{Name: "vim", Current: "8.2.3995-1", Latest: "8.2.3995-1ubuntu2", Security: false},
		},
		SecurityCount:  2,
		RebootRequired: true,
		CheckedAt:      time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (c *devCollector) OSUpdateApply() error {
	if devUpdateJob.Running {
		return fmt.Errorf("an upgrade is already running")
	}
	devUpdateJob = shared.OSUpdateJob{Running: true, StartedAt: time.Now().UTC().Format(time.RFC3339)}
	go func() {
		time.Sleep(5 * time.Second)
		devUpdateJob.Running = false
		devUpdateJob.FinishedAt = time.Now().UTC().Format(time.RFC3339)
		devUpdateJob.Output = "simulated upgrade finished: 3 upgraded, 0 newly installed"
	}()
	return nil
}

func (c *devCollector) OSUpdateStatus() (shared.OSUpdateJob, error) { return devUpdateJob, nil }

var devCronEntries = []shared.CronEntry{
	{ID: "crontab:0", Source: "crontab", Minute: "0", Hour: "3", DayMonth: "*", Month: "*", DayWeek: "*",
		Command: "/opt/beacle/backup.sh >> /var/log/beacle-backup.log 2>&1", Editable: true},
	{ID: "crontab:1", Source: "crontab", Minute: "*/5", Hour: "*", DayMonth: "*", Month: "*", DayWeek: "*",
		Command: "/usr/bin/certbot -q renew", Editable: true},
}

func (c *devCollector) CronState() (shared.CronState, error) {
	entries := append([]shared.CronEntry{}, devCronEntries...)
	entries = append(entries,
		shared.CronEntry{Source: "cron.d/sysstat", Minute: "*/10", Hour: "*", DayMonth: "*", Month: "*", DayWeek: "*",
			User: "root", Command: "/usr/lib/sysstat/debian-sa1 1 1"},
		shared.CronEntry{Source: "crontab-system", Minute: "17", Hour: "*", DayMonth: "*", Month: "*", DayWeek: "*",
			User: "root", Command: "cd / && run-parts --report /etc/cron.hourly"},
	)
	return shared.CronState{
		Entries:       entries,
		CronAvailable: true,
		Timers: []shared.SystemdTimer{
			{Unit: "apt-daily.timer", Active: "active", Next: "Wed 2026-09-30 06:00:00 UTC", Last: "Tue 2026-09-29 06:12:44 UTC"},
			{Unit: "logrotate.timer", Active: "active", Next: "Wed 2026-09-30 00:00:00 UTC", Last: "n/a"},
		},
	}, nil
}

func (c *devCollector) CronCreate(spec shared.CronEntrySpec) (shared.CronEntry, error) {
	e := shared.CronEntry{ID: fmt.Sprintf("crontab:%d", len(devCronEntries)), Source: "crontab",
		Minute: spec.Minute, Hour: spec.Hour, DayMonth: spec.DayMonth, Month: spec.Month, DayWeek: spec.DayWeek,
		Command: spec.Command, Editable: true}
	devCronEntries = append(devCronEntries, e)
	return e, nil
}

func (c *devCollector) CronUpdate(id string, spec shared.CronEntrySpec) error {
	for i, e := range devCronEntries {
		if e.ID == id {
			devCronEntries[i].Minute, devCronEntries[i].Hour, devCronEntries[i].DayMonth = spec.Minute, spec.Hour, spec.DayMonth
			devCronEntries[i].Month, devCronEntries[i].DayWeek, devCronEntries[i].Command = spec.Month, spec.DayWeek, spec.Command
			return nil
		}
	}
	return fmt.Errorf("unknown entry %q", id)
}

func (c *devCollector) CronDelete(id string) error {
	for i, e := range devCronEntries {
		if e.ID == id {
			devCronEntries = append(devCronEntries[:i], devCronEntries[i+1:]...)
			for j := range devCronEntries {
				devCronEntries[j].ID = fmt.Sprintf("crontab:%d", j)
			}
			return nil
		}
	}
	return fmt.Errorf("unknown entry %q", id)
}

var devFwRules = []shared.FirewallRule{
	{ID: "1", Action: "allow", Proto: "tcp", Port: "22", Raw: "[ 1] 22/tcp ALLOW IN Anywhere", Protected: true},
	{ID: "2", Action: "allow", Proto: "tcp", Port: "80", Raw: "[ 2] 80/tcp ALLOW IN Anywhere"},
	{ID: "3", Action: "allow", Proto: "tcp", Port: "443", Raw: "[ 3] 443/tcp ALLOW IN Anywhere"},
	{ID: "4", Action: "deny", Proto: "any", Source: "203.0.113.7", Raw: "[ 4] Anywhere DENY IN 203.0.113.7"},
}

func (c *devCollector) FirewallStatus() (shared.FirewallStatus, error) {
	ports, _ := c.Ports()
	return shared.FirewallStatus{
		Backend: "ufw", Enabled: true, DefaultIncoming: "deny", Editable: true,
		Rules: append([]shared.FirewallRule{}, devFwRules...),
		ProtectedPorts: []int{22, 8931},
		OpenPorts:      ports,
	}, nil
}

func (c *devCollector) FirewallDryRun(req shared.FirewallDryRunRequest) (shared.FirewallDryRun, error) {
	if req.Action == "delete" {
		for _, r := range devFwRules {
			if r.ID == req.ID {
				out := shared.FirewallDryRun{Commands: []string{"ufw --force delete " + req.ID}}
				if r.Protected {
					out.Warning = "allows protected port " + r.Port + " — deleting may cut off SSH"
				}
				return out, nil
			}
		}
		return shared.FirewallDryRun{}, fmt.Errorf("rule %q no longer exists", req.ID)
	}
	if req.Spec == nil {
		return shared.FirewallDryRun{}, fmt.Errorf("spec is required")
	}
	cmd := "ufw " + req.Action + " " + req.Spec.Port + "/" + req.Spec.Proto
	if req.Spec.Source != "" {
		cmd += " from " + req.Spec.Source
	}
	return shared.FirewallDryRun{Commands: []string{cmd}}, nil
}

func (c *devCollector) FirewallAllow(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error) {
	devFwRules = append(devFwRules, shared.FirewallRule{
		ID: fmt.Sprintf("%d", len(devFwRules)+1), Action: "allow",
		Proto: spec.Proto, Port: spec.Port, Source: spec.Source,
		Comment: spec.Comment, Raw: "simulated allow",
	})
	return shared.FirewallMutation{OK: true}, nil
}

func (c *devCollector) FirewallDeny(spec shared.FirewallRuleSpec) (shared.FirewallMutation, error) {
	if (spec.Port == "22" || spec.Port == "8931") && spec.Source == "" {
		return shared.FirewallMutation{}, fmt.Errorf("refusing to deny protected port %s to the whole world (ssh/agent guard)", spec.Port)
	}
	devFwRules = append(devFwRules, shared.FirewallRule{
		ID: fmt.Sprintf("%d", len(devFwRules)+1), Action: "deny",
		Proto: spec.Proto, Port: spec.Port, Source: spec.Source,
		Comment: spec.Comment, Raw: "simulated deny",
	})
	return shared.FirewallMutation{OK: true}, nil
}

func (c *devCollector) FirewallDelete(req shared.FirewallDeleteRequest) (shared.FirewallMutation, error) {
	for i, r := range devFwRules {
		if r.ID == req.ID {
			if r.Protected && !req.Force {
				return shared.FirewallMutation{}, fmt.Errorf("allows protected port %s — confirm explicitly to proceed", r.Port)
			}
			devFwRules = append(devFwRules[:i], devFwRules[i+1:]...)
			return shared.FirewallMutation{OK: true}, nil
		}
	}
	return shared.FirewallMutation{}, fmt.Errorf("rule %q no longer exists", req.ID)
}

func (c *devCollector) Reboot(restore bool) (shared.RebootResult, error) {
	if !restore {
		return shared.RebootResult{OK: true}, nil
	}
	devRestore = shared.RestoreResult{
		Restored:   true,
		RestoredAt: time.Now().UTC().Format(time.RFC3339),
		Screens:    []shared.RestoreItemResult{{Name: "bot", OK: true}},
		Nohup:      []shared.RestoreItemResult{{Name: "worker", OK: true}},
	}
	return shared.RebootResult{OK: true, ScreensQueued: 1, NohupQueued: 1}, nil
}

func (c *devCollector) Poweroff() error { return nil }

var devRestore = shared.RestoreResult{}

func (c *devCollector) RestoreStatus() (shared.RestoreResult, error) { return devRestore, nil }

var devWatchdog = shared.WatchdogConfig{}

func (c *devCollector) SetWatchdogConfig(wc shared.WatchdogConfig) error {
	devWatchdog = wc
	return nil
}

func (c *devCollector) SendWatchdogMessage(msg shared.WebhookMessage) error {
	if len(devWatchdog.Webhooks) == 0 {
		return fmt.Errorf("no webhooks configured")
	}
	var firstErr error
	sent := 0
	for _, t := range devWatchdog.Webhooks {
		if err := shared.SendWebhook(t, msg); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		sent++
	}
	if sent == 0 {
		return firstErr
	}
	return nil
}

func (c *devCollector) WatchdogStatus() (shared.WatchdogStatus, error) {
	return shared.WatchdogStatus{
		Enabled: devWatchdog.Enabled, Role: devWatchdog.Role,
		Peers: len(devWatchdog.Peers), Webhooks: len(devWatchdog.Webhooks),
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

// devScreens is mutable so start/stop can be exercised on a dev machine
// without a real VPS — the panel is developed on Windows.
var devScreens = []shared.ScreenSession{
	{PID: 4211, Name: "minecraft", Attached: false, Created: "07/01/2026 10:22:01 AM",
		Running: true, Command: "java -Xmx2G -jar server.jar", ChildPID: 4212},
	{PID: 5100, Name: "botrunner", Attached: true, Created: "07/03/2026 08:12:44 PM"},
}

func (c *devCollector) ScreenSessions() ([]shared.ScreenSession, error) {
	out := make([]shared.ScreenSession, len(devScreens))
	copy(out, devScreens)
	return out, nil
}

func (c *devCollector) ScreenStart(req shared.ScreenStartRequest) error {
	if strings.TrimSpace(req.Command) == "" {
		return fmt.Errorf("command is required")
	}
	for i := range devScreens {
		if devScreens[i].Name != req.Name {
			continue
		}
		if devScreens[i].Running {
			return fmt.Errorf("session %q is already running %s", req.Name, devScreens[i].Command)
		}
		devScreens[i].Running = true
		devScreens[i].Command = req.Command
		devScreens[i].ChildPID = devScreens[i].PID + 1
		return nil
	}
	devScreens = append(devScreens, shared.ScreenSession{
		PID:      9000 + len(devScreens),
		Name:     req.Name,
		Created:  time.Now().Format("01/02/2006 03:04:05 PM"),
		Running:  true,
		Command:  req.Command,
		ChildPID: 9001 + len(devScreens),
	})
	return nil
}

func (c *devCollector) ScreenStop(name string) error {
	for i := range devScreens {
		if devScreens[i].Name != name {
			continue
		}
		if !devScreens[i].Running {
			return fmt.Errorf("nothing is running in session %q", name)
		}
		devScreens[i].Running = false
		devScreens[i].Command = ""
		devScreens[i].ChildPID = 0
		return nil
	}
	return fmt.Errorf("session %q not found", name)
}

// The dev collector fakes nohup jobs in memory, the same way it fakes screen.
var devNohup []shared.NohupJob

func (c *devCollector) NohupJobs() ([]shared.NohupJob, error) { return devNohup, nil }

func (c *devCollector) NohupStart(req shared.NohupStartRequest) (shared.NohupJob, error) {
	for _, j := range devNohup {
		if j.Name == req.Name && j.Running {
			return shared.NohupJob{}, fmt.Errorf("job %q is already running", req.Name)
		}
	}
	job := shared.NohupJob{
		Name: req.Name, PID: 4200 + len(devNohup), Command: req.Command, Dir: req.Dir,
		LogFile: "/var/log/beacle/" + req.Name + ".log",
		Started: time.Now().UTC().Format(time.RFC3339), Running: true,
	}
	devNohup = append(devNohup, job)
	return job, nil
}

func (c *devCollector) NohupStop(name string) error {
	for i := range devNohup {
		if devNohup[i].Name == name {
			devNohup = append(devNohup[:i], devNohup[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("job %q not found", name)
}

func (c *devCollector) NohupLogs(name string) (string, error) {
	for _, j := range devNohup {
		if j.Name == name {
			return "dev collector: fake output for " + j.Command, nil
		}
	}
	return "", fmt.Errorf("job %q not found", name)
}

// The dev collector runs on Windows, where there is no systemd to write to.
// Refusing loudly beats pretending a unit was created.
func (c *devCollector) PreviewSystemdUnit(shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error) {
	return shared.SystemdUnitPreview{}, fmt.Errorf("systemd is only available on Linux hosts")
}

func (c *devCollector) CreateSystemdUnit(shared.SystemdUnitSpec) (shared.SystemdUnitPreview, error) {
	return shared.SystemdUnitPreview{}, fmt.Errorf("systemd is only available on Linux hosts")
}

func (c *devCollector) DeleteSystemdUnit(string) error {
	return fmt.Errorf("systemd is only available on Linux hosts")
}

func (c *devCollector) ScreenKill(name string) error {
	for i := range devScreens {
		if devScreens[i].Name == name {
			devScreens = append(devScreens[:i], devScreens[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("session %q not found", name)
}

func (c *devCollector) ScreenLogs(name string) (string, error) {
	for _, s := range devScreens {
		if s.Name == name {
			if !s.Running {
				return "(session idle — no output)", nil
			}
			return fmt.Sprintf("simulated output of %s in session %s\nline 2\nline 3", s.Command, name), nil
		}
	}
	return "", fmt.Errorf("session %q not found", name)
}

func (c *devCollector) ListDir(path string) (shared.FSListing, error) {
	if path == "" {
		path = "/home"
	}
	if !strings.HasPrefix(path, "/") {
		return shared.FSListing{}, fmt.Errorf("path must be absolute")
	}
	path = strings.TrimSuffix(path, "/")
	if path == "" {
		path = "/"
	}
	parent := path[:strings.LastIndex(path, "/")+1]
	if parent != "" && parent != "/" {
		parent = strings.TrimSuffix(parent, "/")
	}
	if path == "/" {
		parent = ""
	}
	return shared.FSListing{
		Path:   path,
		Parent: parent,
		Entries: []shared.FSEntry{
			{Name: "bot-python", Path: path + "/bot-python", IsDir: true, Mode: "drwxr-xr-x"},
			{Name: "logs", Path: path + "/logs", IsDir: true, Mode: "drwxr-xr-x"},
			{Name: "main.py", Path: path + "/main.py", IsDir: false, Size: 2048, Mode: "-rw-r--r--"},
			{Name: "run.sh", Path: path + "/run.sh", IsDir: false, Size: 512, Mode: "-rwxr-xr-x"},
		},
	}, nil
}

func (c *devCollector) Ping(target string) shared.PingResult {
	return shared.PingResult{
		Target: target, LatencyMs: 5 + c.rng.Float64()*40,
		PacketLoss: 0, Reachable: true,
	}
}
