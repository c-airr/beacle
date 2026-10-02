package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
)

func main() {
	var (
		configPath = flag.String("config", "/opt/beacle-agent/config.json", "path to config file")
		version    = flag.Bool("version", false, "print version and exit")
		join       = flag.String("join", "", "write a WireGuard join token (bcwg1.…) into the config, print the UDP port and exit")
	)
	flag.Parse()

	if *version {
		fmt.Println(AgentVersion)
		return
	}

	if *join != "" {
		cfg, err := LoadConfig(*configPath)
		if errors.Is(err, os.ErrNotExist) {
			cfg, err = &Config{path: *configPath, ListenPort: 8931}, nil
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "config: %v\n", err)
			os.Exit(1)
		}
		if err := applyJoin(cfg, *join); err != nil {
			fmt.Fprintf(os.Stderr, "join: %v\n", err)
			os.Exit(1)
		}
		if err := cfg.Save(); err != nil {
			fmt.Fprintf(os.Stderr, "config: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(cfg.WG.ListenPort)
		return
	}

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}
	col := newCollector(cfg)
	proxy := NewProxyManager(cfg)
	updater := NewUpdater(cfg)
	reporter := NewReporter(cfg, col, proxy)
	// Boot restore from a reboot-with-restore manifest. Backgrounded: it
	// sleeps to let the system settle, and must not delay connecting.
	go maybeRestoreSessions(col)
	api := &APIServer{cfg: cfg, col: col, proxy: proxy, upd: updater, files: &FileManager{root: defaultFilesRoot()}}
	// Automatic updates are parked — see AutoUpdateLoop in updater.go. The agent
	// only replaces its own binary when someone presses Update.
	// go updater.AutoUpdateLoop()
	ws := NewWSClient(cfg, api, reporter)
	api.kickSession = ws.KickSession
	// Fleet watchdog: idle unless this agent is an elected watcher.
	go runWatchdog(cfg, ws)
	ws.Run()
}
