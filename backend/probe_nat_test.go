package main

import (
	"net/netip"
	"os"
	"strings"
	"testing"

	"beacle/shared"
)

// Tests never ask the internet for this machine's address.
func TestMain(m *testing.M) {
	panelPublicIP = func() netip.Addr { return netip.Addr{} }
	os.Exit(m.Run())
}

// A server that reaches the internet through this machine's own address sits
// behind the same router; the panel can never dial its tunnel.
func TestSameNATServerIsNotOfferedWireGuard(t *testing.T) {
	old := panelPublicIP
	panelPublicIP = func() netip.Addr { return netip.MustParseAddr("37.30.32.204") }
	t.Cleanup(func() { panelPublicIP = old })

	p, err := probeServer("37.30.32.204")
	if err != nil {
		t.Fatal(err)
	}
	if p.WireGuardOK || p.Reason != "same_nat" || p.Recommended != shared.TransportTailscale {
		t.Fatalf("probe = %+v, want same_nat / tailscale", p)
	}
	if _, err := wireGuardEndpoint("37.30.32.204", 0); err == nil || !strings.Contains(err.Error(), "same router") {
		t.Fatalf("endpoint err = %v, want same router refusal", err)
	}
	if _, err := wireGuardEndpoint("194.62.1.161", 0); err != nil {
		t.Fatalf("other server refused: %v", err)
	}
}
