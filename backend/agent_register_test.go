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

// A server added in the panel and waiting for its agent has no token yet.
// Another machine on the tailnet used to take it by saying its name and IP
// in the register frame — and with it the token and every command meant for
// it, the first terminal included. Only the address it connects from, or the
// name Tailscale itself gives that address, may match it.
func TestAgentCannotClaimAWaitingServer(t *testing.T) {
	srv := newWGTestServer(t)
	names := map[string]string{"100.64.0.5": "maslo", "100.64.0.99": "intruder"}
	was := tailnetName
	tailnetName = func(ip string) string { return names[ip] }
	t.Cleanup(func() { tailnetName = was })

	byIP := srv.store.CreateVPS("maslo", "maslo", "100.64.0.5")
	byName := srv.store.CreateVPS("arm", "arm", "")
	for _, claim := range []shared.RegisterRequest{
		{TailscaleName: "maslo", TailscaleIP: "100.64.0.5"},
		{TailscaleName: "arm", TailscaleIP: "100.64.0.7"},
	} {
		if e, _, err := srv.registerAgent(claim, "100.64.0.99", "", nil); err == nil {
			t.Fatalf("a tailnet machine claiming %q took %s", claim.TailscaleName, e.VPS.Name)
		}
	}

	if e, ack, err := srv.registerAgent(shared.RegisterRequest{TailscaleName: "maslo"}, "100.64.0.5", "", nil); err != nil || e.VPS.ID != byIP.VPS.ID || ack.Token == "" {
		t.Fatalf("maslo from its own address: %v", err)
	}
	names["100.64.0.7"] = "arm"
	if e, _, err := srv.registerAgent(shared.RegisterRequest{TailscaleName: "arm"}, "100.64.0.7", "", nil); err != nil || e.VPS.ID != byName.VPS.ID {
		t.Fatalf("arm, added by name, from the address Tailscale names arm: %v", err)
	}
}
