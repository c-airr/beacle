package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"time"
)

func main() {
	var (
		addr    = flag.String("addr", "0.0.0.0:9930", "listen address (0.0.0.0 for Tailscale agents)")
		baseURL = flag.String("base-url", "", "Tailscale URL of this backend for install commands")
		dataDir = flag.String("data", "./data", "data directory")
	)
	flag.Parse()

	store, err := NewStore(*dataDir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	hub := NewHub()
	history := NewHistory(*dataDir)
	spikes := NewSpikes(*dataDir)
	alerts := NewAlertEngine(store, hub)
	agentHub := NewAgentHub(store, hub, alerts, history, spikes)
	alerts.SetAgentHub(agentHub)
	webhooks := NewWebhookService(*dataDir, store, agentHub, history)
	wg, err := NewWireGuardService(*dataDir, store)
	if err != nil {
		log.Fatalf("wireguard: %v", err)
	}

	base := *baseURL
	if base == "" {
		if ip := tailscaleSelfIPv4(); ip != "" {
			base = fmt.Sprintf("http://%s:9930", ip)
		} else {
			base = fmt.Sprintf("http://127.0.0.1%s", *addr)
			log.Printf("beacle: tailscale not available, install commands use %s", base)
		}
	}

	srv := &Server{
		store:     store,
		hub:       hub,
		agentHub:  agentHub,
		alerts:    alerts,
		history:   history,
		webhooks:  webhooks,
		wg:        wg,
		spikes:    spikes,
		baseURL:   base,
		dataDir:   *dataDir,
		startedAt: time.Now(),
		uptime:    NewUptimeLog(*dataDir),
	}
	alerts.SetNotifier(webhooks.Enqueue)
	wg.Start(func(w http.ResponseWriter, r *http.Request, e *VPSEntry) {
		agentHub.ServeAgentWSPinned(w, r, srv, e)
	})

	go srv.uptime.Run()
	go store.FlushLoop()
	go history.RunTrim()
	go spikes.RunTrim()
	go alerts.WatchOffline()
	go srv.LinkMonitor()
	go webhooks.Run()
	go webhooks.RunSyncLoop()

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
