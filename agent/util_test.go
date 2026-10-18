package main

import (
	"net"
	"testing"
)

func TestPickLanIP(t *testing.T) {
	ip := func(s string) net.IP { return net.ParseIP(s) }
	home := lanCandidate{ifName: "eth0", up: true, ip: ip("192.168.1.50")}
	tests := []struct {
		name  string
		cands []lanCandidate
		want  string
	}{
		{"home lan", []lanCandidate{home}, "192.168.1.50"},
		{"datacenter public only", []lanCandidate{
			{ifName: "eth0", up: true, ip: ip("146.59.10.20")},
		}, ""},
		{"skips docker bridge", []lanCandidate{
			{ifName: "docker0", up: true, ip: ip("192.168.49.1")},
			home,
		}, "192.168.1.50"},
		{"skips down interface", []lanCandidate{
			{ifName: "eth0", up: false, ip: ip("192.168.1.50")},
		}, ""},
		{"skips tailscale and wg", []lanCandidate{
			{ifName: "tailscale0", up: true, ip: ip("100.89.0.1")},
			{ifName: "wg0", up: true, ip: ip("10.87.0.2")},
		}, ""},
		{"ignores ipv6", []lanCandidate{
			{ifName: "eth0", up: true, ip: ip("fe80::1")},
			home,
		}, "192.168.1.50"},
	}
	for _, tt := range tests {
		if got := pickLanIP(tt.cands); got != tt.want {
			t.Errorf("%s: got %q, want %q", tt.name, got, tt.want)
		}
	}
}
