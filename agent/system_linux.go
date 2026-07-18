//go:build linux

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"beacle/shared"
)

type linuxCollector struct {
	mu            sync.Mutex
	prevCPUIdle   uint64
	prevCPUTotal  uint64
	prevCoreIdle  []uint64
	prevCoreTotal []uint64
	prevNet       map[string][2]uint64 // iface -> rx, tx
	prevNetAt     time.Time
	docker        *dockerClient
}

func newCollector(cfg *Config) Collector {
	return &linuxCollector{
		prevNet: map[string][2]uint64{},
		docker:  newDockerClient(),
	}
}

// --- CPU --------------------------------------------------------------------

type cpuSample struct {
	idle, total uint64
}

func parseCPULine(fields []string) (cpuSample, bool) {
	if len(fields) < 5 {
		return cpuSample{}, false
	}
	var vals []uint64
	for _, s := range fields[1:] {
		v, _ := strconv.ParseUint(s, 10, 64)
		vals = append(vals, v)
	}
	var total uint64
	for _, v := range vals {
		total += v
	}
	idle := vals[3]
	if len(vals) > 4 {
		idle += vals[4] // idle + iowait
	}
	return cpuSample{idle: idle, total: total}, true
}

func readCPUTimes() (idle, total uint64) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 5 || fields[0] != "cpu" {
			continue
		}
		s, ok := parseCPULine(fields)
		if !ok {
			return 0, 0
		}
		return s.idle, s.total
	}
	return 0, 0
}

func readPerCoreCPUTimes() []cpuSample {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return nil
	}
	defer f.Close()
	var cores []cpuSample
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 5 {
			continue
		}
		name := fields[0]
		if name == "cpu" || !strings.HasPrefix(name, "cpu") {
			continue
		}
		s, ok := parseCPULine(fields)
		if !ok {
			continue
		}
		cores = append(cores, s)
	}
	return cores
}

func cpuDeltaPercent(prevIdle, prevTotal, idle, total uint64) float64 {
	if prevTotal == 0 || total <= prevTotal {
		return 0
	}
	dIdle := float64(idle - prevIdle)
	dTotal := float64(total - prevTotal)
	if dTotal <= 0 {
		return 0
	}
	pct := (1 - dIdle/dTotal) * 100
	if pct < 0 {
		return 0
	}
	if pct > 100 {
		return 100
	}
	return pct
}

func (c *linuxCollector) cpuPercent() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	idle, total := readCPUTimes()
	pct := cpuDeltaPercent(c.prevCPUIdle, c.prevCPUTotal, idle, total)
	c.prevCPUIdle, c.prevCPUTotal = idle, total
	return pct
}

func (c *linuxCollector) cpuPerCore() []float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	samples := readPerCoreCPUTimes()
	if len(samples) == 0 {
		return nil
	}
	out := make([]float64, len(samples))
	if len(c.prevCoreTotal) != len(samples) {
		c.prevCoreIdle = make([]uint64, len(samples))
		c.prevCoreTotal = make([]uint64, len(samples))
		for i, s := range samples {
			c.prevCoreIdle[i] = s.idle
			c.prevCoreTotal[i] = s.total
		}
		return out
	}
	for i, s := range samples {
		out[i] = cpuDeltaPercent(c.prevCoreIdle[i], c.prevCoreTotal[i], s.idle, s.total)
		c.prevCoreIdle[i] = s.idle
		c.prevCoreTotal[i] = s.total
	}
	return out
}

func cpuModel() (string, int) {
	f, err := os.Open("/proc/cpuinfo")
	if err != nil {
		return "", runtime.NumCPU()
	}
	defer f.Close()
	model := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "model name") {
			if i := strings.Index(line, ":"); i >= 0 {
				model = strings.TrimSpace(line[i+1:])
				break
			}
		}
	}
	return model, runtime.NumCPU()
}

// --- Memory ------------------------------------------------------------------

func readMeminfo() (total, avail, free, cached, buffers, swapTotal, swapFree uint64) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 {
			continue
		}
		v, _ := strconv.ParseUint(fields[1], 10, 64)
		v *= 1024
		switch strings.TrimSuffix(fields[0], ":") {
		case "MemTotal":
			total = v
		case "MemAvailable":
			avail = v
		case "MemFree":
			free = v
		case "Cached":
			cached = v
		case "Buffers":
			buffers = v
		case "SwapTotal":
			swapTotal = v
		case "SwapFree":
			swapFree = v
		}
	}
	return
}

// --- Disks -------------------------------------------------------------------

// isPhysicalDisk reports block devices worth showing in the panel (skip snap/loop/tmpfs).
func isPhysicalDisk(dev, mount, fstype string) bool {
	switch fstype {
	case "squashfs", "tmpfs", "devtmpfs", "overlay", "autofs", "cifs", "fuse", "fuse.sshfs", "proc", "sysfs":
		return false
	}
	if strings.HasPrefix(mount, "/snap") || strings.HasPrefix(dev, "/dev/loop") {
		return false
	}
	for _, p := range []string{"/dev/sd", "/dev/nvme", "/dev/vd", "/dev/xvd", "/dev/mmcblk", "/dev/md", "/dev/mapper/"} {
		if strings.HasPrefix(dev, p) {
			return true
		}
	}
	return false
}

func diskUsage() []shared.DiskUsage {
	f, err := os.Open("/proc/mounts")
	if err != nil {
		return nil
	}
	defer f.Close()
	seen := map[string]bool{}
	var out []shared.DiskUsage
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 3 {
			continue
		}
		dev, mount, fstype := fields[0], fields[1], fields[2]
		if !isPhysicalDisk(dev, mount, fstype) || seen[dev] {
			continue
		}
		var st syscall.Statfs_t
		if err := syscall.Statfs(mount, &st); err != nil || st.Blocks == 0 {
			continue
		}
		seen[dev] = true
		total := st.Blocks * uint64(st.Bsize)
		free := st.Bavail * uint64(st.Bsize)
		used := total - free
		out = append(out, shared.DiskUsage{
			Mount:       mount,
			Filesystem:  fstype,
			TotalBytes:  total,
			UsedBytes:   used,
			UsedPercent: float64(used) / float64(total) * 100,
		})
	}
	return out
}

// --- Network ------------------------------------------------------------------

func (c *linuxCollector) networkStats() []shared.NetworkStats {
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil
	}
	defer f.Close()
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	dt := now.Sub(c.prevNetAt).Seconds()
	var out []shared.NetworkStats
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		i := strings.Index(line, ":")
		if i < 0 {
			continue
		}
		iface := strings.TrimSpace(line[:i])
		if iface == "lo" || strings.HasPrefix(iface, "veth") || strings.HasPrefix(iface, "br-") || iface == "docker0" {
			continue
		}
		fields := strings.Fields(line[i+1:])
		if len(fields) < 16 {
			continue
		}
		rx, _ := strconv.ParseUint(fields[0], 10, 64)
		tx, _ := strconv.ParseUint(fields[8], 10, 64)
		ns := shared.NetworkStats{Interface: iface, RxBytes: rx, TxBytes: tx}
		if prev, ok := c.prevNet[iface]; ok && dt > 0 {
			if rx >= prev[0] {
				ns.RxPerSec = uint64(float64(rx-prev[0]) / dt)
			}
			if tx >= prev[1] {
				ns.TxPerSec = uint64(float64(tx-prev[1]) / dt)
			}
		}
		c.prevNet[iface] = [2]uint64{rx, tx}
		out = append(out, ns)
	}
	c.prevNetAt = now
	return out
}

// --- Metrics -----------------------------------------------------------------

func (c *linuxCollector) Metrics() (shared.SystemMetrics, error) {
	hostname, _ := os.Hostname()
	memTotal, memAvail, memFree, memCached, memBuffers, swapTotal, swapFree := readMeminfo()
	memUsed := uint64(0)
	if memTotal > memAvail {
		memUsed = memTotal - memAvail
	}
	cacheBytes := memCached + memBuffers
	memUsedCached := uint64(0)
	if memTotal > memFree {
		memUsedCached = memTotal - memFree
	}

	var load1, load5, load15 float64
	if b, err := os.ReadFile("/proc/loadavg"); err == nil {
		fmt.Sscanf(string(b), "%f %f %f", &load1, &load5, &load15)
	}
	var uptime float64
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		fmt.Sscanf(string(b), "%f", &uptime)
	}
	kernel := ""
	if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		kernel = strings.TrimSpace(string(b))
	}
	osName := "Linux"
	if b, err := os.ReadFile("/etc/os-release"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				osName = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), `"`)
				break
			}
		}
	}
	model, cores := cpuModel()
	perCore := c.cpuPerCore()

	m := shared.SystemMetrics{
		Hostname:           hostname,
		OS:                 osName,
		Kernel:             kernel,
		Arch:               runtime.GOARCH,
		CPUPercent:         c.cpuPercent(),
		CPUCores:           cores,
		CPUModel:           model,
		CPUPerCore:         perCore,
		MemTotalBytes:      memTotal,
		MemUsedBytes:       memUsed,
		MemCachedBytes:     cacheBytes,
		MemUsedCachedBytes: memUsedCached,
		SwapTotal:          swapTotal,
		SwapUsed:           swapTotal - swapFree,
		Disks:              diskUsage(),
		UptimeSeconds:      uint64(uptime),
		Load1:              load1,
		Load5:              load5,
		Load15:             load15,
		Network:            c.networkStats(),
		CollectedAt:        time.Now().UTC(),
	}
	if memTotal > 0 {
		m.MemPercent = float64(memUsed) / float64(memTotal) * 100
		m.MemPercentCached = float64(memUsedCached) / float64(memTotal) * 100
	}
	return m, nil
}

// --- Processes ----------------------------------------------------------------

func (c *linuxCollector) Processes() ([]shared.ProcessInfo, error) {
	out, err := exec.Command("ps", "-eo", "pid,user,pcpu,pmem,rss,stat,comm,args", "--sort=-pcpu").Output()
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(out), "\n")
	var procs []shared.ProcessInfo
	for i, line := range lines {
		if i == 0 || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 8 {
			continue
		}
		pid, _ := strconv.Atoi(fields[0])
		cpu, _ := strconv.ParseFloat(fields[2], 64)
		mem, _ := strconv.ParseFloat(fields[3], 64)
		rss, _ := strconv.ParseUint(fields[4], 10, 64)
		procs = append(procs, shared.ProcessInfo{
			PID:        pid,
			User:       fields[1],
			CPUPercent: cpu,
			MemPercent: mem,
			MemBytes:   rss * 1024,
			State:      fields[5],
			Name:       fields[6],
			Command:    strings.Join(fields[7:], " "),
		})
		if len(procs) >= 100 {
			break
		}
	}
	return procs, nil
}

// --- Ping ----------------------------------------------------------------------

func (c *linuxCollector) Ping(target string) shared.PingResult {
	res := shared.PingResult{Target: target}
	out, err := exec.Command("ping", "-c", "4", "-W", "1", "-i", "0.25", target).Output()
	text := string(out)
	if err != nil && !strings.Contains(text, "packet loss") {
		return res
	}
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, "packet loss") {
			for _, part := range strings.Split(line, ",") {
				part = strings.TrimSpace(part)
				if strings.HasSuffix(part, "packet loss") {
					fmt.Sscanf(part, "%f%%", &res.PacketLoss)
				}
			}
		}
		// rtt min/avg/max/mdev = 0.5/0.7/0.9/0.1 ms
		if strings.HasPrefix(line, "rtt") || strings.HasPrefix(line, "round-trip") {
			if i := strings.Index(line, "="); i >= 0 {
				parts := strings.Split(strings.TrimSpace(line[i+1:]), "/")
				if len(parts) >= 2 {
					res.LatencyMs, _ = strconv.ParseFloat(parts[1], 64)
				}
			}
		}
	}
	res.Reachable = res.PacketLoss < 100
	return res
}
