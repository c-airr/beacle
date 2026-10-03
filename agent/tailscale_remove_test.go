package main

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"beacle/shared"
)

// Tailscale is the way back while a WireGuard switch is on trial; removing it
// then would strand the server if the tunnel never comes up.
func TestRemoveTailscaleRefusedUntilWireGuardConfirmed(t *testing.T) {
	cases := []struct {
		name string
		cfg  Config
	}{
		{"tailscale", Config{Transport: shared.TransportTailscale}},
		{"wireguard on trial", Config{
			Transport:          shared.TransportWireGuard,
			WG:                 &WGConfig{},
			FallbackBackendURL: "ws://100.64.0.1:9930/ws/agent",
			FallbackUntil:      time.Now().Add(5 * time.Minute),
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := tc.cfg
			cfg.path = filepath.Join(t.TempDir(), "config.json")
			s := &APIServer{cfg: &cfg}
			rec := httptest.NewRecorder()
			s.handleRemoveTailscale(rec, httptest.NewRequest(http.MethodPost, "/api/transport/tailscale/remove", nil))
			if rec.Code != http.StatusConflict {
				t.Fatalf("code %d, want 409: %s", rec.Code, rec.Body)
			}
		})
	}
}
