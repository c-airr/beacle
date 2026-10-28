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

// After a state.json reset an agent's ID and token match nothing. Anyone on
// the tailnet can claim that, so it waits for the person at the panel; once
// let back in, its next retry connects with the token it already holds.
func TestUnknownAgentWaitsToBeLetBackIn(t *testing.T) {
	srv := newWGTestServer(t)
	was := tailnetName
	tailnetName = func(ip string) string { return map[string]string{"100.64.0.5": "maslo"}[ip] }
	t.Cleanup(func() { tailnetName = was })

	lost := shared.RegisterRequest{VPSID: "vps-lost", Hostname: "maslo", AgentVersion: "2.2.6"}
	if _, _, err := srv.registerAgent(lost, "100.64.0.5", "old-token", nil); err == nil {
		t.Fatal("an agent nobody knows was let in on its own word")
	}
	if srv.store.GetVPS("vps-lost") != nil {
		t.Fatal("the unknown agent was added to the registry")
	}
	// It retries; another machine fills in made-up requests of its own.
	_, _, _ = srv.registerAgent(lost, "100.64.0.5", "old-token", nil)
	for _, id := range []string{"a", "b", "c"} {
		_, _, _ = srv.registerAgent(shared.RegisterRequest{VPSID: id, Hostname: "maslo"}, "100.64.0.99", "x", nil)
	}
	reqs := srv.rejoins.list()
	if len(reqs) != 2 || reqs[0].IP != "100.64.0.5" || reqs[0].TailnetName != "maslo" || reqs[0].VPSID != "vps-lost" {
		t.Fatalf("want one request per address, maslo's first: %+v", reqs)
	}

	refuse := httptest.NewRecorder()
	r := httptest.NewRequest("DELETE", "/api/vps/rejoin/100.64.0.99", nil)
	r.SetPathValue("ip", "100.64.0.99")
	srv.handleRefuseRejoin(refuse, r)
	_, _, _ = srv.registerAgent(shared.RegisterRequest{VPSID: "d"}, "100.64.0.99", "x", nil)
	if n := len(srv.rejoins.list()); refuse.Code != 200 || n != 1 {
		t.Fatalf("a refused machine came back on the list (%d, %d requests)", refuse.Code, n)
	}

	approve := httptest.NewRecorder()
	r = httptest.NewRequest("POST", "/api/vps/rejoin/100.64.0.5", nil)
	r.SetPathValue("ip", "100.64.0.5")
	srv.handleApproveRejoin(approve, r)
	e := srv.store.GetVPS("vps-lost")
	if approve.Code != 200 || e == nil || e.AgentToken != "old-token" || e.VPS.Host != "100.64.0.5" || e.VPS.Status != shared.VPSPending {
		t.Fatalf("approval: %d %s %+v", approve.Code, approve.Body, e)
	}
	tokenEntry := srv.store.FindByToken("old-token")
	got, _, err := srv.registerAgent(lost, "100.64.0.5", "old-token", tokenEntry)
	if err != nil || got.VPS.ID != "vps-lost" || got.VPS.Status != shared.VPSOnline {
		t.Fatalf("the retry after approval: %v %+v", err, got)
	}
	if len(srv.rejoins.list()) != 0 {
		t.Error("the approved request is still listed")
	}
}

// An agent on this computer could drive the panel's API anyway; it is
// adopted back without asking.
func TestLocalAgentIsAdoptedBack(t *testing.T) {
	srv := newWGTestServer(t)
	e, _, err := srv.registerAgent(shared.RegisterRequest{VPSID: "vps-here", Hostname: "desk"}, "127.0.0.1", "tok", nil)
	if err != nil || e.VPS.ID != "vps-here" || e.AgentToken != "tok" {
		t.Fatalf("%v %+v", err, e)
	}
}
