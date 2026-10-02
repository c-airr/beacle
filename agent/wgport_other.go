//go:build !linux

package main

// The dev agent has no host firewall to manage.
func openWireGuardPort(port int) (string, error) { return "dev agent: skipped", nil }
