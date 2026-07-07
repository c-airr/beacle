//go:build linux

package main

import (
	"os/exec"
	"strings"
)

func tailscaleIPv4() string {
	out, err := exec.Command("tailscale", "ip", "-4").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func tailscaleName() string {
	out, err := exec.Command("tailscale", "status", "--json").Output()
	if err != nil {
		return ""
	}
	// minimal parse for HostName from Self
	const key = `"HostName":`
	i := strings.Index(string(out), key)
	if i < 0 {
		return ""
	}
	rest := string(out)[i+len(key):]
	rest = strings.TrimSpace(rest)
	if len(rest) == 0 || rest[0] != '"' {
		return ""
	}
	rest = rest[1:]
	j := strings.IndexByte(rest, '"')
	if j < 0 {
		return ""
	}
	return rest[:j]
}
