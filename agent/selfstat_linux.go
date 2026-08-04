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
	b, err := os.ReadFile("/proc/self/stat")
	if err != nil {
		return 0
	}
	// comm sits in parentheses and can contain spaces, so parse after the last
	// closing one; utime and stime are the 12th and 13th fields from there.
	closeIdx := strings.LastIndexByte(string(b), ')')
	if closeIdx < 0 {
		return 0
	}
	fields := strings.Fields(string(b)[closeIdx+1:])
	if len(fields) < 13 {
		return 0
	}
	utime, err1 := strconv.ParseFloat(fields[11], 64)
	stime, err2 := strconv.ParseFloat(fields[12], 64)
	if err1 != nil || err2 != nil {
		return 0
	}
	return (utime + stime) / clockTicksPerSec
}
