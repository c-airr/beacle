package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// npmAdapter drives Nginx Proxy Manager through its REST API (port 81).
// Requires npm_email / npm_password in the agent config.
type npmAdapter struct {
	baseURL  string
	email    string
	password string

	mu       sync.Mutex
	token    string
	tokenExp time.Time
	http     *http.Client
	lastErr  string
}

func newNPMAdapter(cfg *Config) *npmAdapter {
	return &npmAdapter{
		baseURL:  strings.TrimRight(cfg.NPMURL, "/"),
		email:    cfg.NPMEmail,
		password: cfg.NPMPassword,
		http:     &http.Client{Timeout: 10 * time.Second},
	}
}

func (a *npmAdapter) Kind() shared.ProxyProviderKind { return shared.ProxyProviderNPM }

func (a *npmAdapter) Detect() bool {
	resp, err := a.http.Get(a.baseURL + "/api/")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode < 500
}

func (a *npmAdapter) login() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.token != "" && time.Now().Before(a.tokenExp) {
		return nil
	}
	if a.email == "" || a.password == "" {
		return fmt.Errorf("NPM detected but npm_email/npm_password not set in agent config")
	}
	body, _ := json.Marshal(map[string]string{"identity": a.email, "secret": a.password})
	resp, err := a.http.Post(a.baseURL+"/api/tokens", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("npm login failed (%d): %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	var tok struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tok); err != nil {
		return err
	}
	a.token = tok.Token
	a.tokenExp = time.Now().Add(50 * time.Minute)
	return nil
}

func (a *npmAdapter) do(method, path string, body any, out any) error {
	if err := a.login(); err != nil {
		return err
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, a.baseURL+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+a.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("npm api %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out != nil {
		return json.NewDecoder(resp.Body).Decode(out)
	}
	return nil
}

type npmProxyHost struct {
	ID            int      `json:"id,omitempty"`
	DomainNames   []string `json:"domain_names"`
	ForwardScheme string   `json:"forward_scheme"`
	ForwardHost   string   `json:"forward_host"`
	ForwardPort   int      `json:"forward_port"`
	CertificateID any      `json:"certificate_id,omitempty"` // int or "new"
	SSLForced     npmBool  `json:"ssl_forced,omitempty"`
	Enabled       npmBool  `json:"enabled,omitempty"`
	WebsocketsUpg npmBool  `json:"allow_websocket_upgrade,omitempty"`
	BlockExploits npmBool  `json:"block_exploits,omitempty"`
	Meta          struct {
		LetsencryptAgree bool   `json:"letsencrypt_agree,omitempty"`
		LetsencryptEmail string `json:"letsencrypt_email,omitempty"`
	} `json:"meta,omitempty"`
}

// npmBool tolerates NPM returning booleans as 0/1 integers.
type npmBool bool

func (b *npmBool) UnmarshalJSON(data []byte) error {
	s := string(data)
	*b = s == "true" || s == "1"
	return nil
}
func (b npmBool) MarshalJSON() ([]byte, error) {
	if b {
		return []byte("true"), nil
	}
	return []byte("false"), nil
}

func splitUpstream(upstream string) (scheme, host string, port int) {
	scheme = "http"
	if strings.HasPrefix(upstream, "https://") {
		scheme = "https"
	}
	upstream = strings.TrimPrefix(strings.TrimPrefix(upstream, "https://"), "http://")
	host, portStr, ok := strings.Cut(upstream, ":")
	port = 80
	if ok {
		if p, err := strconv.Atoi(portStr); err == nil {
			port = p
		}
	}
	return
}

func (a *npmAdapter) toSite(h npmProxyHost) shared.ProxySite {
	domain := ""
	if len(h.DomainNames) > 0 {
		domain = h.DomainNames[0]
	}
	ssl := shared.SSLDisabled
	if certID, ok := h.CertificateID.(float64); ok && certID > 0 {
		ssl = shared.SSLActive
	}
	return shared.ProxySite{
		ID:       strconv.Itoa(h.ID),
		Domain:   domain,
		Upstream: fmt.Sprintf("%s://%s:%d", h.ForwardScheme, h.ForwardHost, h.ForwardPort),
		SSL:      ssl,
		Enabled:  bool(h.Enabled),
		Provider: shared.ProxyProviderNPM,
		Extra: map[string]string{
			"websockets":     strconv.FormatBool(bool(h.WebsocketsUpg)),
			"block_exploits": strconv.FormatBool(bool(h.BlockExploits)),
		},
	}
}

func (a *npmAdapter) State() shared.ProxyState {
	st := shared.ProxyState{Provider: shared.ProxyProviderNPM, Running: a.Detect()}
	var hosts []npmProxyHost
	if err := a.do(http.MethodGet, "/api/nginx/proxy-hosts", nil, &hosts); err != nil {
		st.LastError = err.Error()
		return st
	}
	for _, h := range hosts {
		st.Sites = append(st.Sites, a.toSite(h))
	}
	st.LastError = a.lastErr
	return st
}

func buildNPMHost(req shared.ProxySiteRequest) npmProxyHost {
	scheme, host, port := splitUpstream(req.Upstream)
	h := npmProxyHost{
		DomainNames:   []string{req.Domain},
		ForwardScheme: scheme,
		ForwardHost:   host,
		ForwardPort:   port,
		Enabled:       true,
		WebsocketsUpg: req.Extra["websockets"] == "true",
		BlockExploits: req.Extra["block_exploits"] == "true",
	}
	if req.EnableSSL {
		h.CertificateID = "new"
		h.SSLForced = true
		h.Meta.LetsencryptAgree = true
		h.Meta.LetsencryptEmail = req.Extra["letsencrypt_email"]
	}
	return h
}

func (a *npmAdapter) AddSite(req shared.ProxySiteRequest) (shared.ProxySite, error) {
	var created npmProxyHost
	if err := a.do(http.MethodPost, "/api/nginx/proxy-hosts", buildNPMHost(req), &created); err != nil {
		return shared.ProxySite{}, err
	}
	return a.toSite(created), nil
}

func (a *npmAdapter) UpdateSite(id string, req shared.ProxySiteRequest) (shared.ProxySite, error) {
	var updated npmProxyHost
	if err := a.do(http.MethodPut, "/api/nginx/proxy-hosts/"+id, buildNPMHost(req), &updated); err != nil {
		return shared.ProxySite{}, err
	}
	return a.toSite(updated), nil
}

func (a *npmAdapter) DeleteSite(id string) error {
	return a.do(http.MethodDelete, "/api/nginx/proxy-hosts/"+id, nil, nil)
}

// Reload: NPM applies changes through its API immediately; treat as no-op success.
func (a *npmAdapter) Reload() error {
	if !a.Detect() {
		return fmt.Errorf("nginx proxy manager not reachable at %s", a.baseURL)
	}
	return nil
}

func (a *npmAdapter) Validate() shared.ProxyValidateResult {
	if !a.Detect() {
		return shared.ProxyValidateResult{Valid: false, Output: "NPM API not reachable"}
	}
	if err := a.login(); err != nil {
		return shared.ProxyValidateResult{Valid: false, Output: err.Error()}
	}
	return shared.ProxyValidateResult{Valid: true, Output: "NPM API reachable, credentials valid"}
}
