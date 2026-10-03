//go:build !linux

package main

func tailscaleIPv4() string  { return "" }
func tailscaleName() string { return "" }
