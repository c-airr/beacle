package main

import (
	"errors"
	"log"
	"net"
	"net/http"
	"strconv"
	"time"
)

// AgentRoutes is everything a server needs from the panel: its socket and
// the install/download mirror. Nothing here reads panel state or sends a
// command, so this is the only handler ever put on a non-loopback address.
func (s *Server) AgentRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /agent/ws", s.handleAgentWS)
	mux.HandleFunc("GET /install", s.handleInstallScript)
	mux.HandleFunc("GET /download/agent", s.handleDownloadAgent)
	mux.HandleFunc("GET /download/agent/version", s.handleAgentVersion)
	return mux
}

func isLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func serveAgents(addr string, h http.Handler) {
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Printf("agent listener %s: %v", addr, err)
	}
}

// serveAgentsOnTailnet keeps an agents-only listener on this machine's
// Tailscale address, following it when tailscaled starts late or the
// address changes. Pre-2.0 agents dial exactly this: http://<tailnet-ip>:9930.
func serveAgentsOnTailnet(port int, h http.Handler) {
	var (
		cur     string
		srv     *http.Server
		lastErr string
	)
	for {
		ip := cur
		if ip == "" || !hasLocalAddr(ip) {
			ip = tailscaleSelfIPv4()
		}
		if ip != cur {
			if srv != nil {
				_ = srv.Close()
				srv = nil
			}
			cur = ""
			if ip != "" {
				addr := net.JoinHostPort(ip, strconv.Itoa(port))
				ln, err := net.Listen("tcp", addr)
				if err != nil {
					if err.Error() != lastErr {
						log.Printf("agent listener %s: %v", addr, err)
						lastErr = err.Error()
					}
				} else {
					srv = &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second}
					go func(s *http.Server) { _ = s.Serve(ln) }(srv)
					cur, lastErr = ip, ""
					log.Printf("agents via Tailscale on %s", addr)
				}
			}
		}
		time.Sleep(30 * time.Second)
	}
}

func hasLocalAddr(ip string) bool {
	want := net.ParseIP(ip)
	addrs, err := net.InterfaceAddrs()
	if err != nil || want == nil {
		return false
	}
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.Equal(want) {
			return true
		}
	}
	return false
}
