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
	"slices"
	"strings"
	"time"
)

// Manifest is manifest.json of a plugin package.
type Manifest struct {
	ID          string      `json:"id"`
	Name        string      `json:"name"`
	Version     string      `json:"version"`
	Permissions Permissions `json:"permissions"`
	// Metrics are keyed by name; a name ending in "*" ("disk_*") covers
	// every metric that starts with what comes before it.
	Metrics map[string]MetricDef `json:"metrics,omitempty"`
	// Config is the form the user fills in under Settings → Plugins.
	Config []ConfigField `json:"config,omitempty"`
	// Timeout is how long a task or handler may run, in seconds (default 10,
	// at most 300). A long one holds the plugin: its other tasks and its
	// slots wait.
	Timeout int `json:"timeout,omitempty"`
}

// ConfigField is one setting. Type is text, secret, number, bool, url or
// select. A secret never leaves the panel's computer (agent parts do not get
// it); a url's host may be called by beacle.http without being listed in
// permissions.http, since the user typed it in.
type ConfigField struct {
	Key     string   `json:"key"`
	Label   string   `json:"label,omitempty"`
	Type    string   `json:"type,omitempty"`
	Default any      `json:"default,omitempty"`
	Help    string   `json:"help,omitempty"`
	Options []string `json:"options,omitempty"` // select only
}

var configTypes = []string{"", "text", "secret", "number", "bool", "url", "select"}

// Permissions is everything a plugin may touch outside its own Lua state.
// The user sees it before installing.
type Permissions struct {
	Read []string `json:"read,omitempty"` // path prefixes beacle.read/list may open
	Exec []string `json:"exec,omitempty"` // programs beacle.exec may run
	HTTP []string `json:"http,omitempty"` // hosts beacle.http may call; "*" is any
	// Write is path prefixes beacle.write may create or change (agent).
	Write []string `json:"write,omitempty"`
	// API is the panel's own API, for beacle.api (backend): "METHOD /path",
	// where * stands for one path segment and METHOD may be *.
	API []string `json:"api,omitempty"`
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
	metricRe = regexp.MustCompile(`^[a-z0-9_]{1,32}\*?$`)
	apiRe    = regexp.MustCompile(`^(\*|GET|POST|PUT|PATCH|DELETE) /api/[A-Za-z0-9_./*{}-]*$`)
)

// MaxTimeout is the longest Timeout a manifest may ask for.
const MaxTimeout = 300

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
	for _, p := range append(slices.Clone(m.Permissions.Read), m.Permissions.Write...) {
		// Agents are Linux; a relative prefix would depend on the agent's cwd.
		if !path.IsAbs(p) {
			return fmt.Errorf("manifest: path %q must be absolute", p)
		}
	}
	for _, a := range m.Permissions.API {
		if !apiRe.MatchString(a) || strings.Contains(a, "..") {
			return fmt.Errorf("manifest: api entry %q must be \"METHOD /api/...\"", a)
		}
	}
	if m.Timeout < 0 || m.Timeout > MaxTimeout {
		return fmt.Errorf("manifest: timeout must be 0-%d seconds", MaxTimeout)
	}
	seen := map[string]bool{}
	for _, f := range m.Config {
		if !metricRe.MatchString(f.Key) || strings.HasSuffix(f.Key, "*") || seen[f.Key] {
			return fmt.Errorf("manifest: config key %q must be 1-32 of a-z 0-9 _, once", f.Key)
		}
		seen[f.Key] = true
		if !slices.Contains(configTypes, f.Type) {
			return fmt.Errorf("manifest: config %q has unknown type %q", f.Key, f.Type)
		}
		if f.Type == "select" && len(f.Options) == 0 {
			return fmt.Errorf("manifest: config %q is a select without options", f.Key)
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

// MetricDef finds a metric's declaration, by its exact name or by a
// wildcard one ("disk_*" declares "disk_sda").
func (m Manifest) MetricDef(name string) (MetricDef, bool) {
	return LookupMetric(m.Metrics, name)
}

// LookupMetric is MetricDef over any map keyed by name or by MetricKey.
func LookupMetric(defs map[string]MetricDef, name string) (MetricDef, bool) {
	if d, ok := defs[name]; ok {
		return d, true
	}
	best := ""
	for k := range defs {
		if pre, ok := strings.CutSuffix(k, "*"); ok && strings.HasPrefix(name, pre) && len(k) > len(best) {
			best = k
		}
	}
	if best == "" {
		return MetricDef{}, false
	}
	return defs[best], true
}

// CallTimeout is how long one of this plugin's tasks or handlers may run.
func (m Manifest) CallTimeout() time.Duration {
	if m.Timeout > 0 {
		return time.Duration(m.Timeout) * time.Second
	}
	return CallTimeout
}
