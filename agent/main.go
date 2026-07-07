package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	var (
		configPath = flag.String("config", "/opt/beacle-agent/config.json", "path to config file")
		version    = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *version {
		fmt.Println(AgentVersion)
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
	api := &APIServer{cfg: cfg, col: col, proxy: proxy, upd: updater}
	go updater.AutoUpdateLoop()
	reporter.Register()
	ws := NewWSClient(cfg, api, reporter)
	ws.Run()
}
