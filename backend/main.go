package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
)

func main() {
	var (
		addr    = flag.String("addr", "0.0.0.0:8930", "listen address (0.0.0.0 for Tailscale agents)")
		baseURL = flag.String("base-url", "", "Tailscale URL of this backend for install commands")
		dataDir = flag.String("data", "./data", "data directory")
	)
	flag.Parse()

	store, err := NewStore(*dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	hub := NewHub()
	alerts := NewAlertEngine(store, hub)
	agentHub := NewAgentHub(store, hub, alerts)

	base := *baseURL
	if base == "" {
		if ip := tailscaleSelfIPv4(); ip != "" {
			base = fmt.Sprintf("http://%s:8930", ip)
		} else {
			base = fmt.Sprintf("http://127.0.0.1%s", *addr)
			log.Printf("beacle: tailscale not available, install commands use %s", base)
		}
	}

	srv := &Server{
		store:    store,
		hub:      hub,
		agentHub: agentHub,
		alerts:   alerts,
		baseURL:  base,
		dataDir:  *dataDir,
	}

	go alerts.WatchOffline()
	go srv.LinkMonitor()

	log.Printf("beacle backend listening on %s (agents via Tailscale: %s)", *addr, base)
	if err := http.ListenAndServe(*addr, withCORS(srv.Routes())); err != nil {
		log.Fatal(err)
	}
}

// withCORS allows the Flutter desktop app (and dev tools) to call the API.
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
