package main

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"beacle/shared"
)

func TestJoinRewritesConfigPrivately(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	// An install from before 2.0: world-readable, Tailscale URL, old creds.
	if err := os.WriteFile(path, []byte(`{"backend_url":"http://100.64.0.5:9930","vps_id":"old","token":"stale","listen_port":8931}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	priv, _ := shared.GenerateWGPrivateKey()
	peer, _ := shared.GenerateWGPrivateKey()
	peerPub, _ := peer.PublicKey()
	psk, _ := shared.GenerateWGPresharedKey()
	j := shared.WGJoin{
		PrivateKey: priv.String(), PeerPublicKey: peerPub.String(), PresharedKey: psk.String(),
		Address: "10.87.0.7", PeerAddress: shared.WGBackendTunnelIP, ListenPort: 51931, VPSID: "new",
	}
	if err := applyJoin(cfg, j.Encode()); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	got, err := LoadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if !got.IsWireGuard() || got.BackendURL != "http://10.87.0.1:9930" || got.VPSID != "new" || got.Token != "" {
		t.Fatalf("config after join: %+v", got)
	}
	if got.WG.PrivateKey != priv.String() || got.WG.ListenPort != 51931 {
		t.Fatalf("wireguard section: %+v", got.WG)
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
			t.Fatalf("config mode %o, want 600", st.Mode().Perm())
		}
	}
	if err := applyJoin(cfg, "bcwg1.garbage"); err == nil {
		t.Fatal("garbage token accepted")
	}
}
