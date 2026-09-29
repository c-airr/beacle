package wgnet

import (
	"context"
	"fmt"
	"io"
	"net/netip"
	"runtime"
	"testing"
	"time"

	"beacle/shared"
)

func pair(t *testing.T) (backend, agent *Tunnel, bPub, aPub shared.WGKey) {
	t.Helper()
	bPriv, _ := shared.GenerateWGPrivateKey()
	aPriv, _ := shared.GenerateWGPrivateKey()
	psk, _ := shared.GenerateWGPresharedKey()
	bPub, _ = bPriv.PublicKey()
	aPub, _ = aPriv.PublicKey()

	var err error
	agent, err = Up(Config{PrivateKey: aPriv, Address: netip.MustParseAddr("10.87.0.2")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(agent.Close)
	backend, err = Up(Config{PrivateKey: bPriv, Address: netip.MustParseAddr("10.87.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(backend.Close)

	if err := agent.SetPeer(Peer{PublicKey: bPub, PresharedKey: psk, AllowedIP: netip.MustParsePrefix("10.87.0.1/32")}); err != nil {
		t.Fatal(err)
	}
	if err := backend.SetPeer(Peer{
		PublicKey:    aPub,
		PresharedKey: psk,
		Endpoint:     fmt.Sprintf("127.0.0.1:%d", agent.ListenPort()),
		AllowedIP:    netip.MustParsePrefix("10.87.0.2/32"),
		Keepalive:    1,
	}); err != nil {
		t.Fatal(err)
	}
	return backend, agent, bPub, aPub
}

// The agent never knows the backend's address: the backend initiates, the
// agent answers the observed endpoint and then dials back through the tunnel.
func TestAgentDialsBackendThroughTunnel(t *testing.T) {
	backend, agent, bPub, aPub := pair(t)

	ln, err := backend.Net.ListenTCPAddrPort(netip.MustParseAddrPort("10.87.0.1:9930"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		_, _ = io.WriteString(c, c.RemoteAddr().String())
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := agent.Net.DialContext(ctx, "tcp", "10.87.0.1:9930")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	got, _ := io.ReadAll(c)
	if host, _, _ := cutHost(string(got)); host != "10.87.0.2" {
		t.Fatalf("backend saw remote %q, want the agent's tunnel IP", got)
	}

	bs, _ := backend.Stats()
	if len(bs) != 1 || bs[0].PublicKey != aPub || bs[0].LastHandshake.IsZero() || bs[0].RxBytes == 0 {
		t.Fatalf("backend stats: %+v", bs)
	}
	as, _ := agent.Stats()
	if len(as) != 1 || as[0].PublicKey != bPub || as[0].Endpoint == "" {
		t.Fatalf("agent stats: %+v", as)
	}
}

func TestRemovedPeerCannotReach(t *testing.T) {
	backend, agent, _, aPub := pair(t)
	if err := backend.RemovePeer(aPub); err != nil {
		t.Fatal(err)
	}
	ln, err := backend.Net.ListenTCPAddrPort(netip.MustParseAddrPort("10.87.0.1:9930"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if c, err := agent.Net.DialContext(ctx, "tcp", "10.87.0.1:9930"); err == nil {
		c.Close()
		t.Fatal("dial succeeded after the peer was removed")
	}
}

// The agent runs on small VPSes; the stock bind alone would add ~16 MiB of
// preallocated batch buffers. Keep one live tunnel well under that.
func TestTunnelHeapFootprint(t *testing.T) {
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	backend, agent, _, _ := pair(t)
	ln, err := backend.Net.ListenTCPAddrPort(netip.MustParseAddrPort("10.87.0.1:9930"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		if c, err := ln.Accept(); err == nil {
			_, _ = io.WriteString(c, "ok")
			c.Close()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	c, err := agent.Net.DialContext(ctx, "tcp", "10.87.0.1:9930")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.ReadAll(c)
	c.Close()
	runtime.GC()
	runtime.ReadMemStats(&after)
	perTunnel := (int64(after.HeapInuse) - int64(before.HeapInuse)) / 2
	t.Logf("heap in use per live tunnel: %.2f MiB", float64(perTunnel)/(1<<20))
	if perTunnel > 6<<20 {
		t.Fatalf("one tunnel holds %.1f MiB of heap", float64(perTunnel)/(1<<20))
	}
}

func cutHost(s string) (string, string, bool) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return "", "", false
	}
	return ap.Addr().String(), "", true
}
