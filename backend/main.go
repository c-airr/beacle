package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	var (
		addr    = flag.String("addr", ":8930", "listen address")
		baseURL = flag.String("base-url", "", "public URL of this backend (used in install commands); overrides BEACLE_PUBLIC_URL")
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

	base := os.Getenv("BEACLE_PUBLIC_URL")
	if *baseURL != "" {
		base = *baseURL
	}
	if base == "" {
		// Local-first: install commands use LAN/public best-effort URL.
		base = fmt.Sprintf("http://%s%s", localIP(), *addr)
		log.Printf("beacle: no public URL set, using %s for agent install commands", base)
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

	log.Printf("beacle backend listening on %s (public URL %s)", *addr, base)
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
