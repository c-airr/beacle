//go:build linux

package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// FuzzParsers feeds the same text to every parser of what a server prints or
// keeps on disk. None of it is the agent's own: a hand-edited Caddyfile, a
// crontab, a firewall rule, a process name. A panic here restarts the agent.
func FuzzParsers(f *testing.F) {
	for _, seed := range []string{
		"example.com, www.example.com {\n\treverse_proxy localhost:8080\n}\n",
		"*/5 * * * * root /usr/bin/backup --all # nightly\n",
		"@reboot /opt/run.sh",
		"0100007F:1F90", "[::1]:8080", `users:(("caddy",pid=812,fd=7))`,
		"cpu  2255 34 2290 22625563 6290 127 456 0 0 0",
		"ACCEPT     tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:22",
		`rule family="ipv4" source address="10.0.0.0/8" port port="443" protocol="tcp" accept`,
		"Listing...\nnginx/jammy-updates 1.18.0-6ubuntu14.4 amd64 [upgradable from: 1.18.0-6ubuntu14.3]",
		"  PID %CPU %MEM COMMAND\n    1  0.0  0.1 /sbin/init splash",
		"8000-8100", "22,80,443", "http://10.0.0.2:3000",
		`{"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":22}},{"accept":null}]}`,
		"# beacle-managed {\"name\":\"x\"}\nexample.com {\n}\n",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, s string) {
		parseCaddyfile(s)
		splitAddresses(s)
		splitCronFields(s, 5)
		parseCronLine(s, true)
		parseCronLine(s, false)
		parseCronID(s)
		parseFWPort(s)
		parseFwRichRule(s)
		parseIptablesRules(s)
		parseIptablesLine(s, 1)
		if json.Valid([]byte(s)) {
			parseNftRule(json.RawMessage(s))
		}
		parseHexAddr(s)
		splitListenAddr(s)
		parseSSUsers(s)
		splitManagedFile(s)
		splitUpstream(s)
		parseCPULine(strings.Fields(s))
		parseProcesses(s, map[int]float64{}, 1)
		parseAptUpgradable(s)
	})
}
