//go:build !linux

package main

// The agent ships for Linux; the dev build on Windows has no /proc to read,
// and a wrong number would be worse than an obvious zero.
func processCPUSeconds() float64 { return 0 }
