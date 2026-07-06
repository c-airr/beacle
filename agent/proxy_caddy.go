package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"beacle/shared"
)

// caddyAdapter manages sites as individual files in cfg.CaddyDir (default
// /etc/caddy/beacle.d). It ensures the main Caddyfile imports that directory,
// so Beacle-managed sites never clobber hand-written config.
type caddyAdapter struct {
	dir       string
	caddyfile string
	lastError string
}

func newCaddyAdapter(cfg *Config) *caddyAdapter {
	return &caddyAdapter{dir: cfg.CaddyDir, caddyfile: "/etc/caddy/Caddyfile"}
}

func (a *caddyAdapter) Kind() shared.ProxyProviderKind { return shared.ProxyProviderCaddy }

func (a *caddyAdapter) Detect() bool {
	if _, err := exec.LookPath("caddy"); err != nil {
		return false
	}
	return true
}

func (a *caddyAdapter) running() bool {
	out, err := exec.Command("systemctl", "is-active", "caddy").Output()
	if err == nil && strings.TrimSpace(string(out)) == "active" {
		return true
	}
	// fallback: admin endpoint
	if code, err := httpGetQuick("http://127.0.0.1:2019/config/"); err == nil && code < 500 {
		return true
	}
	return false
}

func (a *caddyAdapter) version() string {
	out, err := exec.Command("caddy", "version").Output()
	if err != nil {
		return ""
	}
	return strings.Fields(strings.TrimSpace(string(out)))[0]
}

// siteMeta is embedded as a JSON comment on the first line of each site file.
type caddySiteMeta struct {
	ID        string            `json:"id"`
	Domain    string            `json:"domain"`
	Upstream  string            `json:"upstream"`
	EnableSSL bool              `json:"enable_ssl"`
	Extra     map[string]string `json:"extra,omitempty"`
}

func (a *caddyAdapter) sitePath(id string) string {
	return filepath.Join(a.dir, id+".caddy")
}

func renderCaddySite(m caddySiteMeta) string {
	meta, _ := json.Marshal(m)
	addr := m.Domain
	if !m.EnableSSL {
		addr = "http://" + m.Domain
	}
	return fmt.Sprintf("# beacle:%s\n%s {\n\treverse_proxy %s\n}\n", meta, addr, m.Upstream)
}

func (a *caddyAdapter) ensureImport() error {
	if err := os.MkdirAll(a.dir, 0o755); err != nil {
		return err
	}
	importLine := fmt.Sprintf("import %s/*.caddy", a.dir)
	b, err := os.ReadFile(a.caddyfile)
	if err != nil {
		if os.IsNotExist(err) {
			return os.WriteFile(a.caddyfile, []byte(importLine+"\n"), 0o644)
		}
		return err
	}
	if strings.Contains(string(b), importLine) {
		return nil
	}
	f, err := os.OpenFile(a.caddyfile, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString("\n# managed by beacle\n" + importLine + "\n")
	return err
}

func (a *caddyAdapter) loadSites() []shared.ProxySite {
	entries, err := os.ReadDir(a.dir)
	if err != nil {
		return nil
	}
	running := a.running()
	var sites []shared.ProxySite
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".caddy") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(a.dir, e.Name()))
		if err != nil {
			continue
		}
		first, _, _ := strings.Cut(string(b), "\n")
		if !strings.HasPrefix(first, "# beacle:") {
			continue
		}
		var m caddySiteMeta
		if json.Unmarshal([]byte(strings.TrimPrefix(first, "# beacle:")), &m) != nil {
			continue
		}
		ssl := shared.SSLDisabled
		if m.EnableSSL {
			if running {
				ssl = shared.SSLActive // Caddy provisions certs automatically
			} else {
				ssl = shared.SSLPending
			}
		}
		sites = append(sites, shared.ProxySite{
			ID: m.ID, Domain: m.Domain, Upstream: m.Upstream,
			SSL: ssl, Enabled: true, Provider: shared.ProxyProviderCaddy, Extra: m.Extra,
		})
	}
	sort.Slice(sites, func(i, j int) bool { return sites[i].Domain < sites[j].Domain })
	return sites
}

func (a *caddyAdapter) State() shared.ProxyState {
	return shared.ProxyState{
		Provider:  shared.ProxyProviderCaddy,
		Running:   a.running(),
		Version:   a.version(),
		Sites:     a.loadSites(),
		LastError: a.lastError,
	}
}

func (a *caddyAdapter) AddSite(req shared.ProxySiteRequest) (shared.ProxySite, error) {
	if err := a.ensureImport(); err != nil {
		return shared.ProxySite{}, err
	}
	m := caddySiteMeta{
		ID: randomID(), Domain: req.Domain, Upstream: req.Upstream,
		EnableSSL: req.EnableSSL, Extra: req.Extra,
	}
	if err := os.WriteFile(a.sitePath(m.ID), []byte(renderCaddySite(m)), 0o644); err != nil {
		return shared.ProxySite{}, err
	}
	if err := a.Reload(); err != nil {
		a.lastError = err.Error()
	} else {
		a.lastError = ""
	}
	return a.siteFromMeta(m), nil
}

func (a *caddyAdapter) UpdateSite(id string, req shared.ProxySiteRequest) (shared.ProxySite, error) {
	path := a.sitePath(id)
	if _, err := os.Stat(path); err != nil {
		return shared.ProxySite{}, fmt.Errorf("site %s not found", id)
	}
	m := caddySiteMeta{
		ID: id, Domain: req.Domain, Upstream: req.Upstream,
		EnableSSL: req.EnableSSL, Extra: req.Extra,
	}
	if err := os.WriteFile(path, []byte(renderCaddySite(m)), 0o644); err != nil {
		return shared.ProxySite{}, err
	}
	if err := a.Reload(); err != nil {
		a.lastError = err.Error()
	} else {
		a.lastError = ""
	}
	return a.siteFromMeta(m), nil
}

func (a *caddyAdapter) siteFromMeta(m caddySiteMeta) shared.ProxySite {
	ssl := shared.SSLDisabled
	if m.EnableSSL {
		ssl = shared.SSLPending
		if a.running() {
			ssl = shared.SSLActive
		}
	}
	return shared.ProxySite{
		ID: m.ID, Domain: m.Domain, Upstream: m.Upstream,
		SSL: ssl, Enabled: true, Provider: shared.ProxyProviderCaddy, Extra: m.Extra,
	}
}

func (a *caddyAdapter) DeleteSite(id string) error {
	if err := os.Remove(a.sitePath(id)); err != nil {
		return fmt.Errorf("site %s not found", id)
	}
	if err := a.Reload(); err != nil {
		a.lastError = err.Error()
	}
	return nil
}

func (a *caddyAdapter) Reload() error {
	// prefer systemd reload; fallback to caddy reload
	if out, err := exec.Command("systemctl", "reload", "caddy").CombinedOutput(); err == nil {
		return nil
	} else if out2, err2 := exec.Command("caddy", "reload", "--config", a.caddyfile, "--adapter", "caddyfile").CombinedOutput(); err2 == nil {
		return nil
	} else {
		return fmt.Errorf("reload failed: %s / %s", strings.TrimSpace(string(out)), strings.TrimSpace(string(out2)))
	}
}

func (a *caddyAdapter) Validate() shared.ProxyValidateResult {
	out, err := exec.Command("caddy", "validate", "--config", a.caddyfile, "--adapter", "caddyfile").CombinedOutput()
	return shared.ProxyValidateResult{Valid: err == nil, Output: strings.TrimSpace(string(out))}
}
