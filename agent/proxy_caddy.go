package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

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
// It is the source of truth the panel edits; the Caddy blocks below it are
// generated from it, so hand-editing the block is lost on the next save.
type caddySiteMeta struct {
	ID        string            `json:"id"`
	Domain    string            `json:"domain"`
	Upstream  string            `json:"upstream"`
	EnableSSL bool              `json:"enable_ssl"`
	Extra     map[string]string `json:"extra,omitempty"`

	RedirectWWW   bool              `json:"redirect_www,omitempty"`
	ForceHTTPS    bool              `json:"force_https,omitempty"`
	WebSocket     bool              `json:"websocket,omitempty"`
	GzipEncoding  bool              `json:"gzip,omitempty"`
	BasicAuthUser string            `json:"basic_auth_user,omitempty"`
	BasicAuthHash string            `json:"basic_auth_hash,omitempty"`
	AccessLog     bool              `json:"access_log,omitempty"`
	Headers       map[string]string `json:"headers,omitempty"`
}

func metaFromRequest(id string, req shared.ProxySiteRequest) caddySiteMeta {
	return caddySiteMeta{
		ID: id, Domain: req.Domain, Upstream: req.Upstream,
		EnableSSL: req.EnableSSL, Extra: req.Extra,
		RedirectWWW:   req.RedirectWWW,
		ForceHTTPS:    req.ForceHTTPS,
		WebSocket:     req.WebSocket,
		GzipEncoding:  req.GzipEncoding,
		BasicAuthUser: req.BasicAuthUser,
		BasicAuthHash: req.BasicAuthHash,
		AccessLog:     req.AccessLog,
		Headers:       req.Headers,
	}
}

func (a *caddyAdapter) sitePath(id string) string {
	return filepath.Join(a.dir, id+".caddy")
}

// validateSiteRequest guards the boundary where panel input becomes Caddy
// config. A newline or a brace here would not "break the site" — it would
// rewrite the server's routing, so this refuses rather than sanitises.
func validateSiteRequest(req shared.ProxySiteRequest) error {
	domain := strings.TrimSpace(req.Domain)
	if domain == "" {
		return fmt.Errorf("domain is required")
	}
	if len(domain) > 253 {
		return fmt.Errorf("domain is too long")
	}
	for _, r := range domain {
		ok := r == '.' || r == '-' || r == '*' ||
			(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
		if !ok {
			return fmt.Errorf("domain may only contain letters, digits, dots, dashes and *")
		}
	}

	up := normalizeUpstream(req.Upstream)
	if up == "" {
		return fmt.Errorf("upstream is required")
	}
	for _, r := range up {
		if r == '\n' || r == '\r' || r == '{' || r == '}' || r == '#' || r == ' ' || r == '\t' {
			return fmt.Errorf("upstream contains an invalid character")
		}
	}

	if (req.BasicAuthUser == "") != (req.BasicAuthHash == "") {
		return fmt.Errorf("basic auth needs both a username and a password hash")
	}
	for _, v := range []string{req.BasicAuthUser, req.BasicAuthHash} {
		if strings.ContainsAny(v, "\n\r{}\t ") {
			return fmt.Errorf("basic auth values contain an invalid character")
		}
	}
	for k, v := range req.Headers {
		if k == "" || strings.ContainsAny(k, "\n\r{}\t ") || strings.ContainsAny(v, "\n\r") {
			return fmt.Errorf("header %q is invalid", k)
		}
	}
	return nil
}

// normalizeUpstream turns what people type ("3000", "localhost:3000",
// "http://127.0.0.1:3000") into something reverse_proxy accepts.
func normalizeUpstream(up string) string {
	up = strings.TrimSpace(up)
	if up == "" {
		return up
	}
	if _, err := strconv.Atoi(up); err == nil {
		return "127.0.0.1:" + up // bare port
	}
	if !strings.Contains(up, "://") && !strings.Contains(up, ":") {
		return up // hostname without a port; leave it alone
	}
	return up
}

// upstreamPort digs the local port out of an upstream so the panel can check
// whether anything is actually listening behind the domain.
func upstreamPort(up string) int {
	up = strings.TrimPrefix(strings.TrimPrefix(up, "http://"), "https://")
	if i := strings.IndexByte(up, '/'); i >= 0 {
		up = up[:i]
	}
	i := strings.LastIndexByte(up, ':')
	if i < 0 {
		return 0
	}
	p, err := strconv.Atoi(up[i+1:])
	if err != nil || p <= 0 || p > 65535 {
		return 0
	}
	return p
}

func renderCaddySite(m caddySiteMeta) string {
	meta, _ := json.Marshal(m)
	var b strings.Builder
	fmt.Fprintf(&b, "# beacle:%s\n", meta)
	fmt.Fprintf(&b, "# Generated by Beacle — edits below are overwritten on save.\n")

	addr := m.Domain
	if !m.EnableSSL {
		addr = "http://" + m.Domain
	}

	// www redirect is its own site block; folding it into the main block would
	// make the canonical host ambiguous.
	if m.RedirectWWW && !strings.HasPrefix(m.Domain, "www.") {
		wwwAddr := "www." + m.Domain
		if !m.EnableSSL {
			wwwAddr = "http://www." + m.Domain
		}
		fmt.Fprintf(&b, "%s {\n\tredir https://%s{uri} permanent\n}\n\n", wwwAddr, m.Domain)
	}

	fmt.Fprintf(&b, "%s {\n", addr)
	if m.GzipEncoding {
		b.WriteString("\tencode gzip zstd\n")
	}
	if m.BasicAuthUser != "" && m.BasicAuthHash != "" {
		fmt.Fprintf(&b, "\tbasic_auth {\n\t\t%s %s\n\t}\n", m.BasicAuthUser, m.BasicAuthHash)
	}
	if len(m.Headers) > 0 {
		b.WriteString("\theader {\n")
		for _, k := range sortedKeys(m.Headers) {
			fmt.Fprintf(&b, "\t\t%s %q\n", k, m.Headers[k])
		}
		b.WriteString("\t}\n")
	}
	if m.AccessLog {
		fmt.Fprintf(&b, "\tlog {\n\t\toutput file /var/log/caddy/%s.log\n\t}\n", m.Domain)
	}

	fmt.Fprintf(&b, "\treverse_proxy %s", normalizeUpstream(m.Upstream))
	if m.WebSocket {
		// Caddy proxies websockets natively; forwarding the real host keeps
		// upstreams that validate Origin working.
		b.WriteString(" {\n\t\theader_up Host {upstream_hostport}\n")
		b.WriteString("\t\theader_up X-Real-IP {remote_host}\n\t}")
	}
	b.WriteString("\n}\n")
	return b.String()
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
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
		sites = append(sites, a.siteFromMetaSSL(m, ssl))
	}

	// Sites written by hand in the main Caddyfile are shown too, otherwise the
	// panel claims a server has no sites while it is happily serving four.
	sites = append(sites, a.loadCaddyfileSites(sites)...)

	sort.Slice(sites, func(i, j int) bool { return sites[i].Domain < sites[j].Domain })
	return sites
}

// loadCaddyfileSites parses the main Caddyfile and returns everything Beacle
// does not already manage. These are read-only unless the block is a plain
// reverse proxy the form can regenerate without losing anything.
func (a *caddyAdapter) loadCaddyfileSites(managed []shared.ProxySite) []shared.ProxySite {
	b, err := os.ReadFile(a.caddyfile)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	for _, s := range managed {
		seen[s.Domain] = true
	}

	var out []shared.ProxySite
	for _, blk := range parseCaddyfile(string(b)) {
		if len(blk.Addresses) == 0 {
			continue
		}
		// The import line pulling in beacle.d is not a site.
		if strings.HasPrefix(blk.Addresses[0], "import ") {
			continue
		}
		domain := strings.TrimPrefix(strings.TrimPrefix(blk.Addresses[0], "https://"), "http://")
		if seen[domain] {
			continue // Beacle manages this one; its own file wins
		}

		kind := classifyBlock(blk.Body)
		upstream := directiveArg(blk.Body, "reverse_proxy")
		editable := editableByForm(blk)

		reason := ""
		if !editable {
			switch {
			case len(blk.Addresses) > 1:
				reason = "Block serves several domains at once — editing here would split them."
			case kind == siteKindStatic:
				reason = "Serves files from disk (root/file_server), which this form does not model."
			case kind == siteKindMixed:
				reason = "Mixes static files with a proxied path via matchers — too much to regenerate safely."
			default:
				reason = "Uses directives this form cannot express, so it is shown as-is."
			}
		}

		ssl := shared.SSLActive
		mode := tlsMode(blk)
		if mode == "none" {
			ssl = shared.SSLDisabled
		}
		if !a.running() && mode != "none" {
			ssl = shared.SSLPending
		}

		port, inUse, healthy := probeUpstream(upstream)
		out = append(out, shared.ProxySite{
			ID:              "caddyfile:" + domain,
			Domain:          domain,
			Domains:         blk.Addresses,
			Upstream:        upstream,
			SSL:             ssl,
			Enabled:         true,
			Provider:        shared.ProxyProviderCaddy,
			UpstreamPort:    port,
			PortInUse:       inUse,
			UpstreamHealthy: healthy,
			Managed:         false,
			Editable:        editable,
			ReadOnlyReason:  reason,
			Kind:            kind,
			TLSMode:         mode,
			SourceFile:      a.caddyfile,
			RawConfig:       blk.Raw,
		})
	}
	return out
}

// probeUpstream answers the question the site list is really asking: is there
// anything behind this domain? A config pointing at a port nothing listens on
// is the most common reverse proxy mistake, and Caddy will happily serve it
// as a 502.
func probeUpstream(upstream string) (port int, listening bool, healthy bool) {
	port = upstreamPort(normalizeUpstream(upstream))
	if port <= 0 {
		return 0, false, false
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout("tcp", addr, 700*time.Millisecond)
	if err != nil {
		return port, false, false
	}
	conn.Close()
	listening = true

	// A listening socket is not the same as a working app, so try HTTP too.
	// Any status at all means something is answering; only transport failure
	// counts as unhealthy.
	client := &http.Client{Timeout: 900 * time.Millisecond}
	resp, err := client.Get("http://" + addr)
	if err == nil {
		resp.Body.Close()
		healthy = true
	}
	return port, listening, healthy
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
	if err := validateSiteRequest(req); err != nil {
		return shared.ProxySite{}, err
	}
	// Caddy refuses to start when two blocks claim the same site address, and
	// that failure takes down every other site on the box — so a clash with a
	// hand-written block has to be caught before anything is written.
	for _, existing := range a.loadCaddyfileSites(nil) {
		for _, d := range existing.Domains {
			bare := strings.TrimPrefix(strings.TrimPrefix(d, "https://"), "http://")
			if strings.EqualFold(bare, strings.TrimSpace(req.Domain)) {
				return shared.ProxySite{}, fmt.Errorf(
					"%s is already defined in %s — remove it there first", bare, a.caddyfile)
			}
		}
	}
	if err := a.ensureImport(); err != nil {
		return shared.ProxySite{}, err
	}
	m := metaFromRequest(randomID(), req)
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
	if err := validateSiteRequest(req); err != nil {
		return shared.ProxySite{}, err
	}
	// Sites parsed out of the main Caddyfile carry a synthetic id. Writing a
	// Beacle file for that domain would leave two blocks serving it, and Caddy
	// refuses to start on a duplicate site address — taking every other site
	// on the box down with it.
	if strings.HasPrefix(id, "caddyfile:") {
		return shared.ProxySite{}, fmt.Errorf(
			"%s is defined in %s; edit it there, or delete it from that file first",
			strings.TrimPrefix(id, "caddyfile:"), a.caddyfile)
	}
	path := a.sitePath(id)
	if _, err := os.Stat(path); err != nil {
		return shared.ProxySite{}, fmt.Errorf("site %s not found", id)
	}
	m := metaFromRequest(id, req)
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
	return a.siteFromMetaSSL(m, ssl)
}

// siteFromMetaSSL is the single place a ProxySite is built, so the list view
// and the save response can never disagree about a site's settings.
func (a *caddyAdapter) siteFromMetaSSL(m caddySiteMeta, ssl shared.SSLStatus) shared.ProxySite {
	port, listening, healthy := probeUpstream(m.Upstream)
	return shared.ProxySite{
		ID: m.ID, Domain: m.Domain, Upstream: m.Upstream,
		SSL: ssl, Enabled: true, Provider: shared.ProxyProviderCaddy, Extra: m.Extra,
		UpstreamPort:    port,
		PortInUse:       listening,
		UpstreamHealthy: healthy,
		Managed:         true,
		Editable:        true,
		Kind:            siteKindProxy,
		SourceFile:      a.sitePath(m.ID),
		RawConfig:       renderCaddySite(m),
		RedirectWWW:     m.RedirectWWW,
		ForceHTTPS:      m.ForceHTTPS,
		WebSocket:       m.WebSocket,
		GzipEncoding:    m.GzipEncoding,
		BasicAuthUser:   m.BasicAuthUser,
		BasicAuthHash:   m.BasicAuthHash,
		AccessLog:       m.AccessLog,
		Headers:         m.Headers,
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
