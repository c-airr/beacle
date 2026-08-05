//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
)

// processCPUSeconds is how much CPU this agent has used since it started,
// straight from its own /proc entry. Comparing it against uptime turns "the
// panel feels heavy" into a number.
func processCPUSeconds() float64 {
	return float64(processCPUTicks()) / clockTicksPerSec
}

// processCPUTicks is utime+stime from /proc/self/stat, in USER_HZ ticks.
func processCPUTicks() uint64 {
	b, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return 0
	}
	closeIdx := strings.LastIndexByte(string(b), ')')
	if closeIdx < 0 {
		return 0
	}
	fields := strings.Fields(string(b)[closeIdx+1:])
	if len(fields) < 13 {
		return 0
	}
	utime, err1 := strconv.ParseUint(fields[11], 10, 64)
	stime, err2 := strconv.ParseUint(fields[12], 10, 64)
	if err1 != nil || err2 != nil {
		return 0
	}
	return utime + stime
}
