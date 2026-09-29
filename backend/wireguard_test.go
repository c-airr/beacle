package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"beacle/shared"
	"beacle/shared/wgnet"
	"github.com/gorilla/websocket"
)

func newWGTestServer(t *testing.T) *Server {
	t.Helper()
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	hub := NewHub()
	history := NewHistory(dir)
	spikes := NewSpikes(dir)
	alerts := NewAlertEngine(store, hub)
	agentHub := NewAgentHub(store, hub, alerts, history, spikes)
	alerts.SetAgentHub(agentHub)
	wg, err := NewWireGuardService(dir, store)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(wg.Close)
	srv := &Server{
		store: store, hub: hub, agentHub: agentHub, alerts: alerts, history: history,
		spikes: spikes, webhooks: NewWebhookService(dir, store, agentHub, history),
		wg: wg, dataDir: dir, startedAt: time.Now(), uptime: NewUptimeLog(dir),
	}
	wg.Start(func(w http.ResponseWriter, r *http.Request, e *VPSEntry) {
		agentHub.ServeAgentWSPinned(w, r, srv, e)
	})
	return srv
}

// registerThroughTunnel plays the agent: tunnel from the join token, then
// the WebSocket register handshake to the backend's tunnel address.
func registerThroughTunnel(t *testing.T, srv *Server, entry *VPSEntry, claimID string) shared.RegisterResponse {
	t.Helper()
	join, err := srv.wg.JoinFor(entry)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := shared.DecodeWGJoin(join.Encode())
	if err != nil {
		t.Fatal(err)
	}
	priv, _ := shared.ParseWGKey(decoded.PrivateKey)
	peer, _ := shared.ParseWGKey(decoded.PeerPublicKey)
	psk, _ := shared.ParseWGKey(decoded.PresharedKey)
	agent, err := wgnet.Up(wgnet.Config{PrivateKey: priv, Address: netip.MustParseAddr(decoded.Address)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(agent.Close)
	if err := agent.SetPeer(wgnet.Peer{PublicKey: peer, PresharedKey: psk, AllowedIP: netip.MustParsePrefix(decoded.PeerAddress + "/32")}); err != nil {
		t.Fatal(err)
	}
	// The real agent listens on a fixed public port; here the backend is
	// pointed at wherever the test agent landed.
	updated := srv.store.UpdateVPSNow(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.WGEndpoint = fmt.Sprintf("127.0.0.1:%d", agent.ListenPort())
	})
	if err := srv.wg.SyncPeer(updated); err != nil {
		t.Fatal(err)
	}

	dialer := websocket.Dialer{
		NetDialContext:   agent.Net.DialContext,
		HandshakeTimeout: 10 * time.Second,
	}
	wsURL := strings.Replace(decoded.BackendURL(), "http://", "ws://", 1) + "/agent/ws"
	conn, _, err := dialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s through tunnel: %v", wsURL, err)
	}
	defer conn.Close()
	reg := shared.AgentWSMessage{Type: shared.AgentWSRegister, Register: &shared.RegisterRequest{
		VPSID: claimID, Hostname: "vps-under-test", AgentVersion: "test", TailscaleIP: "100.64.9.9",
	}}
	if err := conn.WriteJSON(reg); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		var msg shared.AgentWSMessage
		if err := conn.ReadJSON(&msg); err != nil {
			t.Fatalf("waiting for register ack: %v", err)
		}
		switch msg.Type {
		case shared.AgentWSRegisterAck:
			return *msg.RegisterAck
		case shared.AgentWSError:
			t.Fatalf("register rejected: %s", msg.Error)
		}
	}
}

func TestWireGuardAgentRegistersThroughTunnel(t *testing.T) {
	srv := newWGTestServer(t)
	entry, err := srv.wg.CreateServer("wg-box", "192.0.2.10:51931")
	if err != nil {
		t.Fatal(err)
	}

	// Claiming another server's ID must not matter: the peer key decides.
	ack := registerThroughTunnel(t, srv, entry, "someone-else")
	if ack.VPSID != entry.VPS.ID || ack.Token == "" {
		t.Fatalf("ack = %+v, want pinned to %s with a token", ack, entry.VPS.ID)
	}
	got := srv.store.GetVPS(entry.VPS.ID)
	if got.WGAgentKey != "" {
		t.Fatal("agent private key kept after first contact")
	}
	if got.VPS.Status != shared.VPSOnline || !got.VPS.IsWireGuard() {
		t.Fatalf("status %s transport %q", got.VPS.Status, got.VPS.Transport)
	}
	if got.VPS.Host != "127.0.0.1" {
		t.Fatalf("host %q, want the endpoint address, not the reported Tailscale IP", got.VPS.Host)
	}
	if _, err := srv.wg.JoinFor(got); err == nil {
		t.Fatal("install command still available after the key was used")
	}
	if st := srv.wg.Status(); !st.Running || len(st.Peers) != 1 || st.Peers[0].LastHandshake == 0 {
		t.Fatalf("status: %+v", st)
	}
}

func TestWireGuardServerNotClaimableOverTailscale(t *testing.T) {
	srv := newWGTestServer(t)
	entry, err := srv.wg.CreateServer("wg-box", "192.0.2.11:51931")
	if err != nil {
		t.Fatal(err)
	}
	ack := registerThroughTunnel(t, srv, entry, "")
	tokenEntry := srv.store.FindByToken(ack.Token)
	if _, _, err := srv.registerAgent(shared.RegisterRequest{VPSID: entry.VPS.ID}, "100.64.1.2", ack.Token, tokenEntry); err == nil {
		t.Fatal("token accepted on the Tailscale listener for a WireGuard server")
	}
	if _, _, err := srv.registerAgent(shared.RegisterRequest{VPSID: entry.VPS.ID}, "100.64.1.2", "", nil); err == nil {
		t.Fatal("VPS ID accepted on the Tailscale listener for a WireGuard server")
	}
}

func TestRekeyInvalidatesOldKey(t *testing.T) {
	srv := newWGTestServer(t)
	entry, _ := srv.wg.CreateServer("wg-box", "192.0.2.12:51931")
	oldJoin, _ := srv.wg.JoinFor(entry)
	rekeyed, err := srv.wg.Rekey(entry.VPS.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	newJoin, err := srv.wg.JoinFor(rekeyed)
	if err != nil {
		t.Fatal(err)
	}
	if oldJoin.PrivateKey == newJoin.PrivateKey || oldJoin.PresharedKey == newJoin.PresharedKey {
		t.Fatal("rekey kept the old secrets")
	}
	if newJoin.Address != oldJoin.Address {
		t.Fatal("rekey moved the tunnel address")
	}
	if st := srv.wg.Status(); len(st.Peers) != 1 {
		t.Fatalf("peers after rekey: %+v", st.Peers)
	}
}

func TestCreateWireGuardVPSValidatesAddress(t *testing.T) {
	srv := newWGTestServer(t)
	h := srv.Routes()
	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/vps", bytes.NewBufferString(body)))
		return rec
	}
	for _, bad := range []string{"100.100.1.1", "127.0.0.1", "0.0.0.0", "not an ip"} {
		if rec := post(fmt.Sprintf(`{"transport":"wireguard","public_ip":%q}`, bad)); rec.Code != http.StatusBadRequest {
			t.Errorf("%s: code %d, want 400", bad, rec.Code)
		}
	}
	rec := post(`{"transport":"wireguard","public_ip":"203.0.113.5","name":"edge"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("create: %d %s", rec.Code, rec.Body)
	}
	var v shared.VPS
	_ = json.Unmarshal(rec.Body.Bytes(), &v)
	if v.WGEndpoint != "203.0.113.5:51931" || v.WGTunnelIP != "10.87.0.2" {
		t.Fatalf("vps: %+v", v)
	}
	// Second add of the same pending server reuses it.
	rec = post(`{"transport":"wireguard","public_ip":"203.0.113.5","name":"edge2"}`)
	var again shared.VPS
	_ = json.Unmarshal(rec.Body.Bytes(), &again)
	if again.ID != v.ID {
		t.Fatal("re-adding a pending server created a duplicate")
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/vps/"+v.ID+"/wireguard/install", nil))
	var inst map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &inst)
	cmd, _ := inst["install_command"].(string)
	if !strings.Contains(cmd, "--wg "+shared.WGJoinPrefix) {
		t.Fatalf("install command %q", cmd)
	}
}

// The panel API must not be reachable through the tunnel — only the socket.
func TestTunnelListenerServesOnlyAgentSocket(t *testing.T) {
	srv := newWGTestServer(t)
	entry, _ := srv.wg.CreateServer("wg-box", "192.0.2.13:51931")
	registerThroughTunnel(t, srv, entry, "")
	// The key was dropped at first contact; a fresh one gives a second tunnel
	// to send plain HTTP through.
	rekeyed, _ := srv.wg.Rekey(entry.VPS.ID, "")
	join, _ := srv.wg.JoinFor(rekeyed)
	priv, _ := shared.ParseWGKey(join.PrivateKey)
	peer, _ := shared.ParseWGKey(join.PeerPublicKey)
	psk, _ := shared.ParseWGKey(join.PresharedKey)
	agent, err := wgnet.Up(wgnet.Config{PrivateKey: priv, Address: netip.MustParseAddr(join.Address)})
	if err != nil {
		t.Fatal(err)
	}
	defer agent.Close()
	_ = agent.SetPeer(wgnet.Peer{PublicKey: peer, PresharedKey: psk, AllowedIP: netip.MustParsePrefix(join.PeerAddress + "/32")})
	updated := srv.store.UpdateVPSNow(entry.VPS.ID, func(e *VPSEntry) {
		e.VPS.WGEndpoint = fmt.Sprintf("127.0.0.1:%d", agent.ListenPort())
	})
	_ = srv.wg.SyncPeer(updated)

	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return agent.Net.DialContext(ctx, network, addr)
		},
	}}
	for _, path := range []string{"/api/vps", "/api/shutdown", "/api/vps/" + entry.VPS.ID + "/agent/api/system/reboot"} {
		resp, err := client.Get(join.BackendURL() + path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s through the tunnel: %d, want 404", path, resp.StatusCode)
		}
	}
}
