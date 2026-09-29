//go:build !linux

package main

// No host control outside Linux: the dev collector simulates the endpoints,
// and there is nothing to restore at startup.
func maybeRestoreSessions(col Collector) {}
