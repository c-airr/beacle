package main

import (
	"log"

	"beacle/shared"
)

// ensureWireGuardPort opens the tunnel's UDP port in the host firewall and
// logs the outcome. Called when the agent starts in WireGuard mode (a fresh
// --wg install starts it right after writing the config) and when the panel
// switches a Tailscale agent over, since that path runs no install script.
func ensureWireGuardPort(cfg *Config) {
	if cfg == nil || !cfg.IsWireGuard() {
		return
	}
	port := cfg.WG.ListenPort
	if port <= 0 {
		port = shared.WGDefaultPort
	}
	did, err := openWireGuardPort(port)
	if err != nil {
		log.Printf("wireguard: could not open udp/%d in the host firewall: %v", port, err)
		return
	}
	log.Printf("wireguard: host firewall: %s", did)
}
