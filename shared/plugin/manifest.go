// Package plugin runs Beacle plugins: Lua 5.1 (gopher-lua) in a sandbox,
// shared by the agent (agent.lua) and the backend (backend.lua). Each side
// opens the host functions it offers; this package only knows Lua and the
// permissions a manifest grants.
package plugin

import (
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"strings"
)

// Manifest is manifest.json of a plugin package.
type Manifest struct {
	ID          string               `json:"id"`
	Name        string               `json:"name"`
	Version     string               `json:"version"`
	Permissions Permissions          `json:"permissions"`
	Metrics     map[string]MetricDef `json:"metrics,omitempty"`
}

// Permissions is everything a plugin may touch outside its own Lua state.
// The user sees it before installing.
type Permissions struct {
	Read []string `json:"read,omitempty"` // path prefixes beacle.read/list may open
	Exec []string `json:"exec,omitempty"` // programs beacle.exec may run
	HTTP []string `json:"http,omitempty"` // hosts beacle.http may call
}

// MetricDef declares one value the agent part reports. Warn/Crit raise an
// alert when the value reaches them; 0 means no alert at that level.
type MetricDef struct {
	Label string  `json:"label,omitempty"`
	Unit  string  `json:"unit,omitempty"`
	Warn  float64 `json:"warn,omitempty"`
	Crit  float64 `json:"crit,omitempty"`
}

var (
	idRe     = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
	metricRe = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)
)

// ParseManifest reads and validates manifest.json.
func ParseManifest(b []byte) (Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return m, fmt.Errorf("manifest.json: %w", err)
	}
	return m, m.Validate()
}

func (m Manifest) Validate() error {
	if !idRe.MatchString(m.ID) {
		return fmt.Errorf("manifest: id %q must be 1-32 of a-z 0-9 _ -", m.ID)
	}
	if strings.TrimSpace(m.Name) == "" || strings.TrimSpace(m.Version) == "" {
		return fmt.Errorf("manifest: name and version are required")
	}
	for _, p := range m.Permissions.Read {
		// Agents are Linux; a relative prefix would depend on the agent's cwd.
		if !path.IsAbs(p) {
			return fmt.Errorf("manifest: read path %q must be absolute", p)
		}
	}
	for _, c := range m.Permissions.Exec {
		if c == "" || strings.ContainsAny(c, " \t") {
			return fmt.Errorf("manifest: exec entry %q must be a program name or path", c)
		}
	}
	for _, h := range m.Permissions.HTTP {
		if h == "" || strings.ContainsAny(h, "/: ") {
			return fmt.Errorf("manifest: http entry %q must be a bare host name", h)
		}
	}
	for name, d := range m.Metrics {
		if !metricRe.MatchString(name) {
			return fmt.Errorf("manifest: metric %q must be 1-32 of a-z 0-9 _", name)
		}
		if d.Warn != 0 && d.Crit != 0 && d.Crit < d.Warn {
			return fmt.Errorf("manifest: metric %q has crit below warn", name)
		}
	}
	return nil
}

// MetricKey is how a plugin metric is named everywhere outside the plugin:
// in snapshots, history and alerts.
func MetricKey(pluginID, metric string) string { return pluginID + "." + metric }
