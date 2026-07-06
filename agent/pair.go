package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

// runPairSet handles: beacle set <token> --backend <url> [--write-only]
func runPairSet(args []string) {
	fs := flag.NewFlagSet("set", flag.ExitOnError)
	backend := fs.String("backend", "", "backend/hub URL")
	writeOnly := fs.Bool("write-only", false, "only write config, do not start agent")
	configPath := fs.String("config", "/opt/beacle-agent/config.json", "config path")
	_ = fs.Parse(args[1:])

	token := fs.Arg(0)
	if token == "" {
		log.Fatal("usage: beacle set <token> --backend <url>")
	}

	backendURL := strings.TrimRight(*backend, "/")
	if backendURL == "" {
		backendURL = strings.TrimRight(os.Getenv("BEACLE_BACKEND_URL"), "/")
	}
	if backendURL == "" {
		// bootstrap from pairing endpoint on same host as install
		log.Fatal("beacle set: --backend URL required")
	}

	resp, err := http.Get(backendURL + "/api/pairing/" + token)
	if err != nil {
		log.Fatalf("pairing bootstrap: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		log.Fatalf("pairing bootstrap %d: %s", resp.StatusCode, string(body))
	}
	var boot struct {
		BackendURL   string `json:"backend_url"`
		PairingToken string `json:"pairing_token"`
	}
	if err := json.Unmarshal(body, &boot); err != nil {
		log.Fatalf("pairing bootstrap: bad json: %v", err)
	}
	if boot.BackendURL != "" {
		backendURL = strings.TrimRight(boot.BackendURL, "/")
	}

	cfg := &Config{
		BackendURL:     backendURL,
		PairingToken:   token,
		ReportInterval: 5,
		path:           *configPath,
	}
	if err := os.MkdirAll("/opt/beacle-agent", 0o755); err == nil || os.IsExist(err) {
		_ = os.MkdirAll("/opt/beacle-agent", 0o755)
	}
	if err := cfg.Save(); err != nil {
		log.Fatalf("save config: %v", err)
	}
	fmt.Printf("beacle: paired with backend %s\n", backendURL)
	if *writeOnly {
		return
	}
	runAgent(*configPath)
}

func runAgent(configPath string) {
	cfg, err := LoadConfig(configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
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
