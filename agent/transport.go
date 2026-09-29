package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"beacle/shared"
	"beacle/shared/wgnet"
)

// WGConfig is the agent's end of Beacle's own tunnel, written from the join
// token by `beacle-agent -join`.
type WGConfig struct {
	PrivateKey    string `json:"private_key"`
	PeerPublicKey string `json:"peer_public_key"`
	PresharedKey  string `json:"preshared_key"`
	Address       string `json:"address"`
	PeerAddress   string `json:"peer_address"`
	ListenPort    int    `json:"listen_port"`
}

func (w *WGConfig) fingerprint() string {
	if w == nil {
		return ""
	}
	return fmt.Sprintf("%s|%s|%s|%s|%s|%d", w.PrivateKey, w.PeerPublicKey, w.PresharedKey, w.Address, w.PeerAddress, w.ListenPort)
}

func wgConfigFromJoin(j shared.WGJoin) *WGConfig {
	return &WGConfig{
		PrivateKey:    j.PrivateKey,
		PeerPublicKey: j.PeerPublicKey,
		PresharedKey:  j.PresharedKey,
		Address:       j.Address,
		PeerAddress:   j.PeerAddress,
		ListenPort:    j.ListenPort,
	}
}

type dialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

// agentTransport decides how the WebSocket reaches the panel. On WireGuard
// the tunnel lives inside this process: the machine gets no interface and
// no route, only one UDP port that answers nothing but authenticated
// handshakes from the panel's key.
type agentTransport struct {
	mu  sync.Mutex
	tun *wgnet.Tunnel
	fp  string
}

var transport agentTransport

// current returns how to reach the panel and where it is. Transport fields
// of cfg are only read and written under t.mu.
func (t *agentTransport) current(cfg *Config) (dialFunc, string, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	d, err := t.dialerLocked(cfg)
	return d, cfg.BackendURL, err
}

// update changes cfg under the transport lock and persists it when fn
// reports a change.
func (t *agentTransport) update(cfg *Config, fn func(*Config) bool) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !fn(cfg) {
		return nil
	}
	return cfg.Save()
}

// dialerLocked builds the tunnel on first use and rebuilds it only when its
// settings change, so reconnects reuse it (and its handshake) instead of
// churning keys.
func (t *agentTransport) dialerLocked(cfg *Config) (dialFunc, error) {
	if !cfg.IsWireGuard() {
		t.closeLocked()
		d := &net.Dialer{
			Timeout: wsHandshakeTimeout,
			// The panel machine can drop off the tailnet without closing
			// anything; keepalives make a half-open socket surface as an error
			// instead of hanging on a read.
			KeepAlive: 15 * time.Second,
		}
		return d.DialContext, nil
	}
	if fp := cfg.WG.fingerprint(); t.tun == nil || fp != t.fp {
		t.closeLocked()
		tun, err := upTunnel(cfg.WG)
		if err != nil {
			return nil, err
		}
		t.tun, t.fp = tun, fp
	}
	return t.tun.Net.DialContext, nil
}

func (t *agentTransport) closeLocked() {
	if t.tun != nil {
		t.tun.Close()
		t.tun, t.fp = nil, ""
	}
}

// lastHandshake is when the panel last completed a handshake with us.
func (t *agentTransport) lastHandshake() time.Time {
	t.mu.Lock()
	tun := t.tun
	t.mu.Unlock()
	if tun == nil {
		return time.Time{}
	}
	st, err := tun.Stats()
	if err != nil || len(st) == 0 {
		return time.Time{}
	}
	return st[0].LastHandshake
}

func upTunnel(w *WGConfig) (*wgnet.Tunnel, error) {
	priv, err := shared.ParseWGKey(w.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("wireguard private key: %w", err)
	}
	peer, err := shared.ParseWGKey(w.PeerPublicKey)
	if err != nil {
		return nil, fmt.Errorf("wireguard peer key: %w", err)
	}
	psk, _ := shared.ParseWGKey(w.PresharedKey)
	addr, err := netip.ParseAddr(w.Address)
	if err != nil {
		return nil, fmt.Errorf("wireguard address: %w", err)
	}
	peerAddr, err := netip.ParseAddr(w.PeerAddress)
	if err != nil {
		return nil, fmt.Errorf("wireguard peer address: %w", err)
	}
	port := w.ListenPort
	if port == 0 {
		port = shared.WGDefaultPort
	}
	tun, err := wgnet.Up(wgnet.Config{PrivateKey: priv, ListenPort: port, Address: addr})
	if err != nil {
		return nil, err
	}
	// No endpoint and no keepalive: the panel is usually behind NAT, so it
	// initiates and keeps the path open; this side answers whoever proves
	// the panel's key, from wherever it currently is.
	if err := tun.SetPeer(wgnet.Peer{PublicKey: peer, PresharedKey: psk, AllowedIP: netip.PrefixFrom(peerAddr, 32)}); err != nil {
		tun.Close()
		return nil, err
	}
	return tun, nil
}

// applyJoin points cfg at the panel described by a join token. Credentials
// from an earlier install are dropped: the token names the server now.
func applyJoin(cfg *Config, token string) error {
	j, err := shared.DecodeWGJoin(token)
	if err != nil {
		return err
	}
	url := j.BackendURL()
	if url == "" {
		return errors.New("join token has no panel address")
	}
	cfg.Transport = shared.TransportWireGuard
	cfg.WG = wgConfigFromJoin(j)
	cfg.BackendURL = url
	cfg.VPSID = j.VPSID
	cfg.Token = ""
	cfg.FallbackBackendURL = ""
	cfg.FallbackUntil = time.Time{}
	return nil
}
