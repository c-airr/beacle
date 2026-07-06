package main

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"beacle/shared"
)

// ProxyAdapter is the pluggable interface every reverse proxy provider
// implements. The UI is identical for all providers.
type ProxyAdapter interface {
	Kind() shared.ProxyProviderKind
	Detect() bool
	State() shared.ProxyState
	AddSite(req shared.ProxySiteRequest) (shared.ProxySite, error)
	UpdateSite(id string, req shared.ProxySiteRequest) (shared.ProxySite, error)
	DeleteSite(id string) error
	Reload() error
	Validate() shared.ProxyValidateResult
}

// ProxyManager picks the active provider (Caddy has priority) and caches the
// detection result briefly so periodic reports stay cheap.
type ProxyManager struct {
	mu         sync.Mutex
	adapters   []ProxyAdapter
	active     ProxyAdapter
	detectedAt time.Time
}

func NewProxyManager(cfg *Config) *ProxyManager {
	return &ProxyManager{
		adapters: []ProxyAdapter{
			newCaddyAdapter(cfg),
			newNPMAdapter(cfg),
		},
	}
}

func (m *ProxyManager) Active() ProxyAdapter {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.active != nil && time.Since(m.detectedAt) < 30*time.Second {
		return m.active
	}
	m.active = nil
	for _, a := range m.adapters {
		if a.Detect() {
			m.active = a
			break
		}
	}
	m.detectedAt = time.Now()
	return m.active
}

func (m *ProxyManager) State() shared.ProxyState {
	a := m.Active()
	if a == nil {
		return shared.ProxyState{Provider: shared.ProxyProviderNone}
	}
	return a.State()
}

var errNoProvider = fmt.Errorf("no reverse proxy provider detected (install Caddy or Nginx Proxy Manager)")

func (m *ProxyManager) AddSite(req shared.ProxySiteRequest) (shared.ProxySite, error) {
	a := m.Active()
	if a == nil {
		return shared.ProxySite{}, errNoProvider
	}
	return a.AddSite(req)
}

func (m *ProxyManager) UpdateSite(id string, req shared.ProxySiteRequest) (shared.ProxySite, error) {
	a := m.Active()
	if a == nil {
		return shared.ProxySite{}, errNoProvider
	}
	return a.UpdateSite(id, req)
}

func (m *ProxyManager) DeleteSite(id string) error {
	a := m.Active()
	if a == nil {
		return errNoProvider
	}
	return a.DeleteSite(id)
}

func (m *ProxyManager) Reload() error {
	a := m.Active()
	if a == nil {
		return errNoProvider
	}
	return a.Reload()
}

func (m *ProxyManager) Validate() shared.ProxyValidateResult {
	a := m.Active()
	if a == nil {
		return shared.ProxyValidateResult{Valid: false, Output: errNoProvider.Error()}
	}
	return a.Validate()
}

// httpGetQuick does a fast GET and returns the status code (health probes).
func httpGetQuick(url string) (int, error) {
	c := &http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}
