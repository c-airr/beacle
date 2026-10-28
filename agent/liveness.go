package main

import (
	"context"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"beacle/shared"
)

// Liveness listener: the agent's only inbound socket. It answers one route,
// AgentLivenessPath, so a fleet watcher can tell "this agent is dead" apart
// from "the panel lost its tunnel to it" — the panel alone cannot, and it
// used to page for every agent at once when its own connection blinked.
//
// It binds to the Tailscale address only, never 0.0.0.0, so nothing new is
// exposed to the internet. WireGuard servers have no Tailscale address and
// serve nothing; watchers then fall back to probing the host.

const livenessRecheck = time.Minute

type livenessServer struct {
	mu     sync.Mutex
	addr   string
	srv    *http.Server
	cfg    *Config
	tunnel tunnelState
}

// runLiveness keeps the listener bound to the current Tailscale address,
// rebinding when the address appears later (tailscaled starting after the
// agent) or changes.
func runLiveness(cfg *Config, tunnel tunnelState) {
	l := &livenessServer{cfg: cfg, tunnel: tunnel}
	for {
		l.ensure()
		time.Sleep(livenessRecheck)
	}
}

func (l *livenessServer) ensure() {
	ip := ""
	if !l.cfg.IsWireGuard() {
		ip = tailscaleIPv4()
	}
	port := l.cfg.ListenPort
	if port == 0 {
		port = shared.DefaultAgentPort
	}
	want := ""
	if net.ParseIP(ip) != nil {
		want = net.JoinHostPort(ip, strconv.Itoa(port))
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if want == l.addr && (want == "" || l.srv != nil) {
		return
	}
	if l.srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = l.srv.Shutdown(ctx)
		cancel()
		l.srv = nil
	}
	l.addr = want
	if want == "" {
		return
	}
	ln, err := net.Listen("tcp", want)
	if err != nil {
		// Retried on the next recheck; addr is cleared so it is.
		log.Printf("liveness: listen %s: %v", want, err)
		l.addr = ""
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET "+shared.AgentLivenessPath, l.handle)
	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 3 * time.Second,
		WriteTimeout:      3 * time.Second,
		IdleTimeout:       10 * time.Second,
	}
	l.srv = srv
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("liveness: serve: %v", err)
		}
	}()
	log.Printf("liveness: answering on %s", want)
}

func (l *livenessServer) handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(shared.AgentLiveness{
		ID:      l.cfg.VPSID,
		Version: AgentVersion,
		Backend: l.tunnel != nil && l.tunnel.isConnected(),
	})
}

var livenessHTTP = &http.Client{Timeout: 4 * time.Second}

// agentAlive asks a peer's liveness listener whether its agent runs. Only a
// well-formed answer from the right agent counts: a refused or silent port
// (older agent, firewall, dead process) is "not alive", so a verification
// can only ever suppress an alert on positive proof.
func agentAlive(peer shared.WatchdogPeer) bool {
	_, ok := agentLiveness(peer)
	return ok
}

// agentLiveness is the peer's answer, ok only from the right agent.
func agentLiveness(peer shared.WatchdogPeer) (shared.AgentLiveness, bool) {
	var live shared.AgentLiveness
	if peer.Host == "" {
		return live, false
	}
	port := peer.AgentPort
	if port == 0 {
		port = shared.DefaultAgentPort
	}
	url := "http://" + net.JoinHostPort(peer.Host, strconv.Itoa(port)) + shared.AgentLivenessPath
	resp, err := livenessHTTP.Get(url)
	if err != nil {
		return live, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return live, false
	}
	if err := json.NewDecoder(resp.Body).Decode(&live); err != nil {
		return live, false
	}
	return live, live.ID != "" && live.ID == peer.ID
}
