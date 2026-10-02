package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"time"
)

func main() {
	var (
		addr = flag.String("addr", "127.0.0.1:9930", "panel API listen address; keep it on loopback — it runs commands on every server")
		// The agent listeners serve only /agent/ws and the install mirror.
		agentLoopback = flag.String("agent-loopback", "127.0.0.1:9931", "agents-only loopback listener (target for `tailscale serve`); empty disables")
		agentTailnet  = flag.Bool("agent-tailnet", true, "agents-only listener on this machine's Tailscale IP, same port as -addr")
		baseURL       = flag.String("base-url", "", "Tailscale URL of this backend for install commands")
		dataDir       = flag.String("data", "./data", "data directory")
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
	alerts.SetWireGuard(wg)

	base := *baseURL
	if base == "" {
		if ip := tailscaleSelfIPv4(); ip != "" {
			base = fmt.Sprintf("http://%s:9930", ip)
		} else {
			_, port, _ := net.SplitHostPort(*addr)
			base = fmt.Sprintf("http://127.0.0.1:%s", port)
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

	if isLoopbackAddr(*addr) {
		agents := srv.AgentRoutes()
		if *agentLoopback != "" {
			go serveAgents(*agentLoopback, agents)
		}
		if *agentTailnet {
			_, port, _ := net.SplitHostPort(*addr)
			p, _ := strconv.Atoi(port)
			go serveAgentsOnTailnet(p, agents)
		}
	} else {
		// An explicit public bind (headless deployments behind their own
		// proxy) already carries /agent/ws; a second listener would collide.
		log.Printf("beacle: panel API is exposed on %s — anyone who reaches it can run commands on your servers", *addr)
	}

	log.Printf("beacle backend listening on %s (agents via Tailscale: %s)", *addr, base)
	if err := http.ListenAndServe(*addr, rejectBrowsers(srv.Routes())); err != nil {
		log.Fatal(err)
	}
}

// rejectBrowsers keeps web pages away from the panel API. Loopback is not a
// boundary for a browser: any site the user visits can fetch
// http://127.0.0.1:9930, and with permissive CORS it could list the servers
// and then reboot them, rewrite firewall rules or open a root shell. The
// desktop app talks over dart:io, which sends neither header checked here;
// browsers always send at least one of them on a cross-site request.
func rejectBrowsers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fromBrowser(r) {
			writeErr(w, http.StatusForbidden, "browser requests are not accepted")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func fromBrowser(r *http.Request) bool {
	if r.Header.Get("Origin") != "" {
		return true
	}
	// Sent by browsers on every request, including plain <img>/<form>
	// navigations that carry no Origin; "none" means the user typed the URL.
	site := r.Header.Get("Sec-Fetch-Site")
	return site != "" && site != "none"
}
