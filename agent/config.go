package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"beacle/shared"
)

const AgentVersion = "2.0.0"

// Config is written by the installer with just the backend URL. VPSID and
// Token start empty - the agent auto-registers on first start and persists
// the credentials assigned by the backend. Updates never overwrite this file;
// only the agent itself saves credentials into it.
type Config struct {
	BackendURL     string `json:"backend_url"`
	VPSID          string `json:"vps_id,omitempty"`
	Token          string `json:"token,omitempty"`
	ListenPort int    `json:"listen_port"`

	// Reverse proxy adapter settings (optional)
	NPMURL      string `json:"npm_url,omitempty"`      // default http://127.0.0.1:81
	NPMEmail    string `json:"npm_email,omitempty"`
	NPMPassword string `json:"npm_password,omitempty"`
	CaddyDir    string `json:"caddy_dir,omitempty"` // default /etc/caddy/beacle.d

	// Transport is how the WebSocket reaches the panel: blank/"tailscale"
	// dials BackendURL directly, "wireguard" dials it through the in-process
	// tunnel described by WG.
	Transport string    `json:"transport,omitempty"`
	WG        *WGConfig `json:"wireguard,omitempty"`
	// During a trial switch to WireGuard: where to go back to if the tunnel
	// has not registered by FallbackUntil. Cleared once it has.
	FallbackBackendURL string    `json:"fallback_backend_url,omitempty"`
	FallbackUntil      time.Time `json:"fallback_until,omitempty"`

	path string // where this config was loaded from
}

func (c *Config) IsWireGuard() bool {
	return c.Transport == shared.TransportWireGuard && c.WG != nil
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
	if c.NPMURL == "" {
		c.NPMURL = "http://127.0.0.1:81"
	}
	if c.CaddyDir == "" {
		c.CaddyDir = "/etc/caddy/beacle.d"
	}
	return &c, nil
}

// StateDir is where the agent keeps files of its own — currently the offline
// sample buffer. Alongside the config, which is somewhere the agent already
// has permission to write and which the installer leaves alone on update.
func (c *Config) StateDir() string {
	if c.path == "" {
		return "."
	}
	return filepath.Dir(c.path)
}

// Save persists the config (used once, to store credentials received during
// auto-registration).
func (c *Config) Save() error {
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	// Rename over the old file rather than rewriting it: WriteFile keeps an
	// existing file's mode, and installers before 2.0 created this one 0644 —
	// too open for a file that now holds a private key.
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	_ = os.Chmod(tmp, 0o600)
	return os.Rename(tmp, c.path)
}
