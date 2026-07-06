//go:build linux

package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"beacle/shared"
)

// inodeToPID scans /proc/*/fd to map socket inodes to processes.
func inodeToPID() map[uint64]int {
	m := map[uint64]int{}
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
			if strings.HasPrefix(link, "socket:[") {
				inode, err := strconv.ParseUint(link[8:len(link)-1], 10, 64)
				if err == nil {
					m[inode] = pid
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
	inodes := inodeToPID()
	var all []shared.PortInfo
	all = append(all, parseNetFile("/proc/net/tcp", "tcp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/tcp6", "tcp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/udp", "udp", true, inodes)...)
	all = append(all, parseNetFile("/proc/net/udp6", "udp", true, inodes)...)

	// dedupe by (proto, port, pid)
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
