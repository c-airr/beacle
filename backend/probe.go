package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"beacle/shared"
)

// Localized Windows prints "czas=12ms" or "Zeit=12ms", but TTL= and the
// "<n>ms" figure are the same everywhere.
var pingLatencyRe = regexp.MustCompile(`[=<]\s?(\d+(?:[.,]\d+)?)\s?ms`)

// icmpPing sends one echo through the system ping, which needs no
// privileges on any desktop OS (raw sockets would on Windows).
func icmpPing(ip string) (ok bool, latencyMs float64) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		cmd = exec.CommandContext(ctx, "ping", "-n", "1", "-w", "2000", ip)
	} else {
		cmd = exec.CommandContext(ctx, "ping", "-c", "1", "-W", "2", ip)
	}
	out, _ := hideConsole(cmd).CombinedOutput()
	s := string(out)
	// Windows exits 0 for "Destination host unreachable" from a router, so
	// only an echo reply (which carries a TTL) counts.
	if !strings.Contains(strings.ToUpper(s), "TTL=") {
		return false, 0
	}
	if m := pingLatencyRe.FindStringSubmatch(s); m != nil {
		latencyMs, _ = strconv.ParseFloat(strings.ReplaceAll(m[1], ",", "."), 64)
	}
	return true, latencyMs
}

// resolveServerIP turns what the user typed (IP or hostname) into one IP,
// preferring IPv4 — most VPS providers hand out IPv6 without inbound UDP.
func resolveServerIP(host string) (netip.Addr, error) {
	host = strings.TrimSpace(host)
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap(), nil
	}
	if host == "" || strings.ContainsAny(host, " /\\") {
		return netip.Addr{}, errors.New("enter the server's public IP address")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return netip.Addr{}, errors.New("could not resolve " + host)
	}
	for _, ip := range ips {
		if ip.Unmap().Is4() {
			return ip.Unmap(), nil
		}
	}
	return ips[0], nil
}

// probeServer decides whether WireGuard can work for this address. The
// panel dials the server, so what matters is whether the server's address
// accepts traffic from outside: a CG-NAT address never does.
func probeServer(host string) (shared.ConnectivityProbe, error) {
	ip, err := resolveServerIP(host)
	if err != nil {
		return shared.ConnectivityProbe{}, err
	}
	if ip.IsUnspecified() || ip.IsMulticast() {
		return shared.ConnectivityProbe{}, errors.New("that is not a server address")
	}
	p := shared.ConnectivityProbe{Host: strings.TrimSpace(host), IP: ip.String(), Class: shared.ClassifyIP(ip.String())}
	switch p.Class {
	case shared.IPInvalid, shared.IPLoopback:
		return p, errors.New("that is not a server address")
	case shared.IPCGNAT:
		p.Recommended = shared.TransportTailscale
		p.Reason = "cgnat"
		return p, nil
	}
	p.PingOK, p.LatencyMs = icmpPing(ip.String())
	switch {
	case p.Class == shared.IPPrivate && !p.PingOK:
		p.Recommended = shared.TransportTailscale
		p.Reason = "private_unreachable"
	case p.Class == shared.IPPrivate:
		p.WireGuardOK = true
		p.Recommended = shared.TransportWireGuard
		p.Reason = "private"
	default:
		p.WireGuardOK = true
		p.Recommended = shared.TransportWireGuard
		if !p.PingOK {
			// Plenty of providers drop ICMP by default; that says nothing
			// about UDP, so it is a note, not a verdict.
			p.Reason = "ping_blocked"
		}
	}
	return p, nil
}
