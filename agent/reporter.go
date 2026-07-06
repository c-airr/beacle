package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"

	"beacle/shared"
)

// Reporter registers with the backend and pushes AgentReports periodically.
type Reporter struct {
	cfg   *Config
	col   Collector
	proxy *ProxyManager
	http  *http.Client
}

func NewReporter(cfg *Config, col Collector, proxy *ProxyManager) *Reporter {
	return &Reporter{cfg: cfg, col: col, proxy: proxy, http: &http.Client{Timeout: 10 * time.Second}}
}

func (r *Reporter) post(path string, v any) error {
	body, err := r.postBody(path, v)
	if err != nil {
		return err
	}
	_ = body
	return nil
}

func (r *Reporter) postBody(path string, v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, r.cfg.BackendURL+path, bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	if r.cfg.Token != "" {
		req.Header.Set("Authorization", "Bearer "+r.cfg.Token)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := r.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return out, fmt.Errorf("backend %d: %s", resp.StatusCode, string(out))
	}
	return out, nil
}

// Register performs auto-registration. First-time agents (no credentials in
// config) receive a VPS ID + token from the backend and persist them; the
// VPS entry appears in the panel automatically.
func (r *Reporter) Register() {
	hostname, _ := os.Hostname()
	req := shared.RegisterRequest{
		VPSID:        r.cfg.VPSID,
		PairingToken: r.cfg.PairingToken,
		Hostname:     hostname,
		AgentVersion: AgentVersion,
		AgentPort:    0,
		PublicIP:     fetchPublicIP(),
		OS:           runtime.GOOS + "/" + runtime.GOARCH,
	}
	for {
		body, err := r.postBody("/api/agents/register", req)
		if err != nil {
			log.Printf("register failed (retrying in 10s): %v", err)
			time.Sleep(10 * time.Second)
			continue
		}
		var resp shared.RegisterResponse
		if err := json.Unmarshal(body, &resp); err != nil {
			log.Printf("register: bad response (retrying in 10s): %v", err)
			time.Sleep(10 * time.Second)
			continue
		}
		if resp.Token != "" { // first registration: persist assigned credentials
			r.cfg.VPSID = resp.VPSID
			r.cfg.Token = resp.Token
			r.cfg.PairingToken = ""
			if err := r.cfg.Save(); err != nil {
				log.Printf("warning: could not persist credentials: %v", err)
			}
			log.Printf("auto-registered as vps %s", resp.VPSID)
		} else {
			log.Printf("registered with backend %s", r.cfg.BackendURL)
		}
		return
	}
}

func (r *Reporter) BuildReport() shared.AgentReport {
	metrics, err := r.col.Metrics()
	if err != nil {
		log.Printf("metrics: %v", err)
	}
	units, _ := r.col.SystemdUnits()
	screens, _ := r.col.ScreenSessions()
	return shared.AgentReport{
		VPSID:   r.cfg.VPSID,
		Version: AgentVersion,
		Metrics: metrics,
		Docker:  r.col.Docker(),
		Services: shared.ServicesState{
			Systemd: units,
			Screen:  screens,
		},
		Proxy:  r.proxy.State(),
		SentAt: time.Now().UTC(),
	}
}

func (r *Reporter) Run() {
	interval := time.Duration(r.cfg.ReportInterval) * time.Second
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		rep := r.BuildReport()
		if err := r.post("/api/agents/report", rep); err != nil {
			log.Printf("report failed: %v", err)
		}
		<-ticker.C
	}
}
