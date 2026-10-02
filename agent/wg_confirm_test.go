package main

import (
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
)

// A trial switch to WireGuard whose tunnel does not come up registers over the
// Tailscale fallback. That ack must not count as the tunnel working: it used
// to drop the fallback, and the next panel restart left the agent dialing a
// dead tunnel with no way back (seen on a server behind the panel's own NAT).
func TestAckOverFallbackDoesNotConfirmWireGuard(t *testing.T) {
	cfg := &Config{
		Transport:          shared.TransportWireGuard,
		WG:                 &WGConfig{ListenPort: 51931},
		BackendURL:         "http://10.87.0.1:9930",
		FallbackBackendURL: "http://100.99.21.112:9930",
		FallbackUntil:      time.Now().Add(10 * time.Minute),
		path:               filepath.Join(t.TempDir(), "config.json"),
	}
	r := &Reporter{cfg: cfg}

	r.ApplyRegisterAck(shared.RegisterResponse{VPSID: "v1"}, false)
	if cfg.FallbackBackendURL == "" || !cfg.WGFallbackActive() {
		t.Fatal("an ack over the Tailscale fallback dropped the fallback")
	}

	r.ApplyRegisterAck(shared.RegisterResponse{VPSID: "v1"}, true)
	if cfg.FallbackBackendURL != "" {
		t.Fatal("an ack through the tunnel should confirm the switch")
	}
}
