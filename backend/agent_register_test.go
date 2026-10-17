package main

import (
	"net/http/httptest"
	"testing"

	"beacle/shared"
)

func TestAgentCannotClaimAnotherServer(t *testing.T) {
	srv := newWGTestServer(t)
	e := srv.store.CreateVPS("maslo", "maslo", "100.64.0.5")
	_, ack, err := srv.registerAgent(shared.RegisterRequest{TailscaleName: "maslo", TailscaleIP: "100.64.0.5"}, "100.64.0.5", "", nil)
	if err != nil || ack.Token == "" {
		t.Fatalf("first registration: %v %+v", err, ack)
	}

	// Another machine on the tailnet, saying it is maslo: by name and IP, by
	// its VPS ID (readable from /beacle/alive), and with a made-up token.
	impostor := shared.RegisterRequest{VPSID: e.VPS.ID, TailscaleName: "maslo", TailscaleIP: "100.64.0.5"}
	for _, tok := range []string{"", "guessed"} {
		if _, got, err := srv.registerAgent(impostor, "100.64.0.99", tok, nil); err == nil {
			t.Fatalf("impostor (token %q) accepted as maslo, got %+v", tok, got)
		}
	}

	// maslo itself, reinstalled without its token, comes back from its own address.
	_, again, err := srv.registerAgent(shared.RegisterRequest{VPSID: e.VPS.ID}, "100.64.0.5", "", nil)
	if err != nil || again.VPSID != e.VPS.ID {
		t.Fatalf("reclaim from the server's own address: %v %+v", err, again)
	}
	if again.Token == ack.Token {
		t.Fatal("reclaim handed back the old token instead of a new one")
	}
}

func TestForwardedForOnlyFromLoopback(t *testing.T) {
	r := httptest.NewRequest("GET", "/agent/ws", nil)
	r.Header.Set("X-Forwarded-For", "100.64.0.5")
	r.RemoteAddr = "100.64.0.99:41000"
	if got := agentRemoteIP(r); got != "100.64.0.99" {
		t.Fatalf("header from a tailnet client trusted: %s", got)
	}
	r.RemoteAddr = "127.0.0.1:41000" // tailscale serve
	if got := agentRemoteIP(r); got != "100.64.0.5" {
		t.Fatalf("tailscale serve's header ignored: %s", got)
	}
}
