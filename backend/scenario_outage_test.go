package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"beacle/shared"
)

// wsAgent speaks the agent side of /agent/ws: it registers, answers every
// command with 200 and remembers the watchdog sends it was asked to make.
type wsAgent struct {
	name, token string
	conn        *websocket.Conn
	mu          sync.Mutex
	sends       []shared.WebhookMessage
}

func (a *wsAgent) dial(t *testing.T, base string) {
	t.Helper()
	h := http.Header{}
	if a.token != "" {
		h.Set("Authorization", "Bearer "+a.token)
	}
	conn, _, err := websocket.DefaultDialer.Dial(strings.Replace(base, "http://", "ws://", 1)+"/agent/ws", h)
	if err != nil {
		t.Fatalf("%s: dial: %v", a.name, err)
	}
	if err := conn.WriteJSON(shared.AgentWSMessage{Type: shared.AgentWSRegister, Register: &shared.RegisterRequest{
		Hostname: a.name, TailscaleName: a.name, AgentVersion: "test",
	}}); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		var msg shared.AgentWSMessage
		if err := conn.ReadJSON(&msg); err != nil {
			t.Fatalf("%s: waiting for register ack: %v", a.name, err)
		}
		if msg.Type == shared.AgentWSError {
			t.Fatalf("%s: rejected: %s", a.name, msg.Error)
		}
		if msg.Type == shared.AgentWSRegisterAck {
			a.token = msg.RegisterAck.Token
			break
		}
	}
	_ = conn.SetReadDeadline(time.Time{})
	a.conn = conn
	go a.serve(conn)
}

func (a *wsAgent) serve(conn *websocket.Conn) {
	for {
		var msg shared.AgentWSMessage
		if err := conn.ReadJSON(&msg); err != nil {
			return
		}
		if msg.Type != shared.AgentWSCommand || msg.Command == nil {
			continue
		}
		body := json.RawMessage(`{"ok":true}`)
		if msg.Command.Path == "/api/watchdog/send" {
			var wm shared.WebhookMessage
			_ = json.Unmarshal(msg.Command.Body, &wm)
			a.mu.Lock()
			a.sends = append(a.sends, wm)
			a.mu.Unlock()
			body = json.RawMessage(`{"sent":true}`)
		}
		_ = conn.WriteJSON(shared.AgentWSMessage{Type: shared.AgentWSCommandResult, Result: &shared.AgentCommandResult{
			RequestID: msg.Command.RequestID, StatusCode: 200, Body: body,
		}})
	}
}

// cut drops the socket the way a dead line does: no close frame.
func (a *wsAgent) cut() { _ = a.conn.UnderlyingConn().Close() }

func (a *wsAgent) offlineSends() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	var out []string
	for _, m := range a.sends {
		if m.Alert == string(shared.AlertAgentOffline) || m.Alert == string(shared.AlertAgentDown) {
			out = append(out, m.Title)
		}
	}
	return out
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The whole path, over real sockets: three servers, notifications on, and
// this computer's line drops. Tailscale then brings the servers back one at
// a time, and one of them never comes back. Nothing may reach Discord for
// the two that were fine; the one that is gone is reported once.
func TestScenarioHomeLineDropsAndComesBack(t *testing.T) {
	srv := newWGTestServer(t)
	e := srv.alerts
	e.quietUntil = time.Time{}
	line := true
	var lineMu sync.Mutex
	e.net.probe = func() bool { lineMu.Lock(); defer lineMu.Unlock(); return line }
	setLine := func(up bool) { lineMu.Lock(); line = up; lineMu.Unlock() }

	ts := httptest.NewServer(srv.AgentRoutes())
	t.Cleanup(ts.Close)
	go srv.webhooks.Run()
	e.SetNotifier(srv.webhooks.Enqueue)

	agents := map[string]*wsAgent{}
	ids := map[string]string{}
	for _, name := range []string{"fra", "waw", "nyc"} {
		ids[name] = srv.store.CreateVPS(name, name, "").VPS.ID
		e.reach[ids[name]] = reachProbe{up: false, at: time.Now().Add(time.Hour)}
		agents[name] = &wsAgent{name: name}
		agents[name].dial(t, ts.URL)
	}
	waitFor(t, "all three connected", func() bool { return srv.agentHub.ConnectedCount() == 3 })
	if err := srv.webhooks.SetTargets([]shared.WebhookTarget{{Kind: shared.WebhookDiscord, URL: "https://discord.invalid/hook"}}); err != nil {
		t.Fatal(err)
	}

	// The line drops. Every socket dies at once; the panel notices a while
	// later, by which time every LastSeen is older than the offline limit.
	setLine(false)
	for _, a := range agents {
		a.cut()
	}
	waitFor(t, "sockets gone", func() bool { return srv.agentHub.ConnectedCount() == 0 })
	age := func() {
		for _, id := range ids {
			if !srv.agentHub.Connected(id) {
				srv.store.UpdateVPS(id, func(en *VPSEntry) {
					en.VPS.LastSeen = time.Now().UTC().Add(-2 * shared.OfflineAfterSec * time.Second)
				})
			}
		}
	}
	age()
	e.sweepOffline()

	// The line is back, Tailscale is not: still nobody.
	setLine(true)
	e.sweepOffline()
	e.quietUntil = time.Time{} // the grace for the line runs out first
	age()
	e.sweepOffline()

	// fra and waw come back one after the other; nyc does not.
	agents["fra"].dial(t, ts.URL)
	waitFor(t, "fra back", func() bool { return srv.agentHub.Connected(ids["fra"]) })
	e.sweepOffline()
	agents["waw"].dial(t, ts.URL)
	waitFor(t, "waw back", func() bool { return srv.agentHub.Connected(ids["waw"]) })
	e.sweepOffline()

	if n := openAlerts(srv.store); n != 0 {
		t.Fatalf("%d alert(s) open while the servers were still coming back", n)
	}

	// The grace is over and nyc is still gone: that one is real.
	e.quietUntil = time.Time{}
	age()
	e.sweepOffline()
	waitFor(t, "nyc reported to a watcher", func() bool {
		return len(agents["fra"].offlineSends())+len(agents["waw"].offlineSends()) == 1
	})
	for _, name := range []string{"fra", "waw"} {
		for _, title := range append(agents[name].offlineSends(), agents["nyc"].offlineSends()...) {
			if !strings.Contains(title, "nyc") {
				t.Errorf("a watcher was asked to page about a server that is fine: %q", title)
			}
		}
	}
}
