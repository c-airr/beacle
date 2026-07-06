package main

import (
	"encoding/json"
	"os"
)

const AgentVersion = "0.1.0"

// Config is written by the installer with just the backend URL. VPSID and
// Token start empty - the agent auto-registers on first start and persists
// the credentials assigned by the backend. Updates never overwrite this file;
// only the agent itself saves credentials into it.
type Config struct {
	BackendURL     string `json:"backend_url"`
	VPSID          string `json:"vps_id,omitempty"`
	Token          string `json:"token,omitempty"`
	PairingToken   string `json:"pairing_token,omitempty"`
	ListenPort     int    `json:"listen_port"`
	ReportInterval int    `json:"report_interval_seconds"`

	// Reverse proxy adapter settings (optional)
	NPMURL      string `json:"npm_url,omitempty"`      // default http://127.0.0.1:81
	NPMEmail    string `json:"npm_email,omitempty"`
	NPMPassword string `json:"npm_password,omitempty"`
	CaddyDir    string `json:"caddy_dir,omitempty"` // default /etc/caddy/beacle.d

	path string // where this config was loaded from
}

func LoadConfig(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, err
	}
	c.path = path
	if c.ListenPort == 0 {
		c.ListenPort = 8931
	}
	if c.ReportInterval == 0 {
		c.ReportInterval = 5
	}
	if c.NPMURL == "" {
		c.NPMURL = "http://127.0.0.1:81"
	}
	if c.CaddyDir == "" {
		c.CaddyDir = "/etc/caddy/beacle.d"
	}
	return &c, nil
}

// Save persists the config (used once, to store credentials received during
// auto-registration).
func (c *Config) Save() error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.path, b, 0o600)
}
