//go:build linux

package main

import "beacle/shared"

// Collector surface of the watchdog (the loop itself is platform-neutral).
func (c *linuxCollector) SetWatchdogConfig(wc shared.WatchdogConfig) error {
	return wd.setConfig(c.cfg, wc)
}

func (c *linuxCollector) SendWatchdogMessage(msg shared.WebhookMessage) error {
	return wd.sendAll(msg)
}

func (c *linuxCollector) WatchdogStatus() (shared.WatchdogStatus, error) {
	wc := wd.snapshot()
	return shared.WatchdogStatus{
		Enabled: wc.Enabled, Role: wc.Role,
		Peers: len(wc.Peers), Webhooks: len(wc.Webhooks),
	}, nil
}
