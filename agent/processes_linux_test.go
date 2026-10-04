//go:build linux

package main

import "testing"

func TestParseProcessesDropsItsOwnPs(t *testing.T) {
	out := "    PID USER     %CPU %MEM   RSS STAT COMMAND         COMMAND\n" +
		"      1 root      0.0  0.1 12156 Ss   systemd         /sbin/init\n" +
		"    823 root      1.3  0.5 40000 Ssl  tailscaled      /usr/sbin/tailscaled --port=41641\n" +
		"   4242 root     98.0  0.0  3000 R    ps              ps -eo pid,user,pcpu,pmem,rss,stat,comm,args\n"
	procs := parseProcesses(out, map[int]float64{823: 7.5}, 4242)
	if len(procs) != 2 {
		t.Fatalf("got %d processes: %+v", len(procs), procs)
	}
	if procs[0].PID != 823 || procs[0].CPUPercent != 7.5 {
		t.Fatalf("busiest should be tailscaled at its live 7.5%%, got %+v", procs[0])
	}
	if procs[0].Command != "/usr/sbin/tailscaled --port=41641" || procs[0].MemBytes != 40000*1024 {
		t.Fatalf("fields %+v", procs[0])
	}
}
