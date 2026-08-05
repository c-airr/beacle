//go:build linux

package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"beacle/shared"
)

// inodeToPID maps socket inodes to PIDs. needed, when non-nil, is the set of
// inodes we still care about — once every one of them is found the walk stops.
// The old code always scanned every fd of every process, which on a VPS with
// a few hundred processes was the single most expensive thing the agent did
// on a quiet host.
func inodeToPID(needed map[uint64]struct{}) map[uint64]int {
	m := map[uint64]int{}
	remaining := -1
	if needed != nil {
		remaining = len(needed)
		if remaining == 0 {
			return m
		}
	}
	procs, err := os.ReadDir("/proc")
	if err != nil {
		return m
	}
	for _, p := range procs {
		pid, err := strconv.Atoi(p.Name())
		if err != nil {
			continue
		}
		fds, err := os.ReadDir(filepath.Join("/proc", p.Name(), "fd"))
		if err != nil {
			continue
		}
		for _, fd := range fds {
			link, err := os.Readlink(filepath.Join("/proc", p.Name(), "fd", fd.Name()))
			if err != nil {
				continue
			}
			if !strings.HasPrefix(link, "socket:[") {
				continue
			}
			inode, err := strconv.ParseUint(link[8:len(link)-1], 10, 64)
			if err != nil {
				continue
			}
			if needed != nil {
				if _, ok := needed[inode]; !ok {
					continue
				}
			}
			if _, ok := m[inode]; ok {
				continue
			}
			m[inode] = pid
			if remaining > 0 {
				remaining--
				if remaining == 0 {
					return m
				}
			}
		}
	}
	return m
}

func procName(pid int) (name, cmdline string) {
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/comm", pid)); err == nil {
		name = strings.TrimSpace(string(b))
	}
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid)); err == nil {
		cmdline = strings.TrimSpace(strings.ReplaceAll(string(b), "\x00", " "))
	}
	return
}

// parseHexAddr converts "0100007F:1F90" to ip + port.
func parseHexAddr(s string) (string, int) {
	parts := strings.Split(s, ":")
	if len(parts) != 2 {
		return "", 0
	}
	port64, _ := strconv.ParseUint(parts[1], 16, 32)
	raw, err := hex.DecodeString(parts[0])
	if err != nil {
		return "", int(port64)
	}
	var ip net.IP
	if len(raw) == 4 {
		ip = net.IPv4(raw[3], raw[2], raw[1], raw[0])
	} else if len(raw) == 16 {
		// bytes are stored as 4 little-endian 32-bit words
		ip = make(net.IP, 16)
		for i := 0; i < 4; i++ {
			ip[i*4+0] = raw[i*4+3]
			ip[i*4+1] = raw[i*4+2]
			ip[i*4+2] = raw[i*4+1]
			ip[i*4+3] = raw[i*4+0]
		}
	}
	return ip.String(), int(port64)
}

func parseNetFile(path, proto string, listenOnly bool, inodes map[uint64]int) []shared.PortInfo {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []shared.PortInfo
	sc := bufio.NewScanner(f)
	sc.Scan() // header
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 10 {
			continue
		}
		state := fields[3]
		// TCP LISTEN = 0A; for UDP accept unconnected (07) sockets
		if listenOnly && proto == "tcp" && state != "0A" {
			continue
		}
		if proto == "udp" && state != "07" {
			continue
		}
		addr, port := parseHexAddr(fields[1])
		inode, _ := strconv.ParseUint(fields[9], 10, 64)
		pi := shared.PortInfo{Port: port, Protocol: proto, ListenAddr: addr}
		if pid, ok := inodes[inode]; ok {
			pi.PID = pid
			pi.ProcessName, pi.CommandLine = procName(pid)
		}
		out = append(out, pi)
	}
	return out
}

func (c *linuxCollector) Ports() ([]shared.PortInfo, error) {
	// ss does the inode→pid join in one shot inside the kernel. Walking
	// /proc/*/fd ourselves was the fallback that burned a core on every poll.
	if out, err := portsViaSS(); err == nil && len(out) > 0 {
		return out, nil
	}
	return portsViaProc()
}

// portsViaSS parses `ss -tulnpH`. One process, no /proc fd walk.
func portsViaSS() ([]shared.PortInfo, error) {
	raw, err := exec.Command("ss", "-tulnpH").Output()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var out []shared.PortInfo
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		// Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
		if len(fields) < 5 {
			continue
		}
		proto := strings.ToLower(fields[0])
		if proto != "tcp" && proto != "udp" {
			continue
		}
		state := fields[1]
		if proto == "tcp" && state != "LISTEN" {
			continue
		}
		addr, port := splitListenAddr(fields[4])
		if port == 0 {
			continue
		}
		pi := shared.PortInfo{Port: port, Protocol: proto, ListenAddr: addr}
		if len(fields) >= 6 {
			pi.PID, pi.ProcessName = parseSSUsers(strings.Join(fields[5:], " "))
			if pi.PID > 0 {
				_, pi.CommandLine = procName(pi.PID)
			}
		}
		key := fmt.Sprintf("%s/%d/%d", pi.Protocol, pi.Port, pi.PID)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, pi)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out, nil
}

// splitListenAddr turns "0.0.0.0:80", "[::]:80" or "*:80" into host + port.
func splitListenAddr(s string) (string, int) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", 0
	}
	// IPv6 in brackets: [::1]:443
	if strings.HasPrefix(s, "[") {
		end := strings.LastIndex(s, "]")
		if end < 0 {
			return "", 0
		}
		host := s[1:end]
		rest := s[end+1:]
		if !strings.HasPrefix(rest, ":") {
			return host, 0
		}
		port, _ := strconv.Atoi(rest[1:])
		return host, port
	}
	i := strings.LastIndex(s, ":")
	if i < 0 {
		return "", 0
	}
	port, _ := strconv.Atoi(s[i+1:])
	host := s[:i]
	if host == "*" {
		host = "0.0.0.0"
	}
	return host, port
}

// parseSSUsers pulls the first pid= and a process name out of the users:(...)
// blob ss prints, e.g. users:(("nginx",pid=812,fd=6))
func parseSSUsers(s string) (pid int, name string) {
	if i := strings.Index(s, "pid="); i >= 0 {
		rest := s[i+4:]
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
			end++
		}
		pid, _ = strconv.Atoi(rest[:end])
	}
	if i := strings.Index(s, `(("`); i >= 0 {
		rest := s[i+3:]
		if j := strings.Index(rest, `"`); j >= 0 {
			name = rest[:j]
		}
	}
	return
}

func portsViaProc() ([]shared.PortInfo, error) {
	// Collect the listening inodes first, then resolve only those — not every
	// socket on the box.
	inodes := inodeToPID(listenInodes())
	var all []shared.PortInfo
	all = append(all, parseNetFile("/proc/net/tcp", "tcp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/tcp6", "tcp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/udp", "udp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/udp6", "udp", true, inodes)...)

	seen := map[string]bool{}
	var out []shared.PortInfo
	for _, p := range all {
		key := fmt.Sprintf("%s/%d/%d", p.Protocol, p.Port, p.PID)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out, nil
}

func mustParseUint(s string) uint64 {
	v, _ := strconv.ParseUint(s, 10, 64)
	return v
}

func listenInodes() map[uint64]struct{} {
	needed := map[uint64]struct{}{}
	add := func(path, proto string) {
		f, err := os.Open(path)
		if err != nil {
			return
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Scan()
		for sc.Scan() {
			fields := strings.Fields(sc.Text())
			if len(fields) < 10 {
				continue
			}
			state := fields[3]
			if proto == "tcp" && state != "0A" {
				continue
			}
			if proto == "udp" && state != "07" {
				continue
			}
			needed[mustParseUint(fields[9])] = struct{}{}
		}
	}
	add("/proc/net/tcp", "tcp")
	add("/proc/net/tcp6", "tcp")
	add("/proc/net/udp", "udp")
	add("/proc/net/udp6", "udp")
	return needed
}

// PortDetail returns port ownership plus a health probe of the backend
// listening there (TCP connect, then a HTTP GET if it speaks HTTP).
func (c *linuxCollector) PortDetail(port int) (shared.PortInfo, error) {
	ports, err := c.Ports()
	if err != nil {
		return shared.PortInfo{}, err
	}
	var found *shared.PortInfo
	for i := range ports {
		if ports[i].Port == port && ports[i].Protocol == "tcp" {
			found = &ports[i]
			break
		}
	}
	if found == nil {
		return shared.PortInfo{Port: port, Protocol: "tcp", HealthDetail: "no listener on this port"}, nil
	}
	pi := *found
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 2*time.Second)
	if err != nil {
		pi.Healthy = false
		pi.HealthDetail = "tcp connect failed: " + err.Error()
		return pi, nil
	}
	_ = conn.Close()
	pi.Healthy = true
	pi.HealthDetail = "tcp connect ok"

	// try HTTP
	httpClient := &net.Dialer{Timeout: 2 * time.Second}
	_ = httpClient
	if resp, err := httpGetQuick(fmt.Sprintf("http://127.0.0.1:%d/", port)); err == nil {
		pi.HealthDetail = fmt.Sprintf("http %d", resp)
		pi.Healthy = resp < 500
	}
	return pi, nil
}
