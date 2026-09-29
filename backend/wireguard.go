package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"time"

	"beacle/shared"
	"beacle/shared/wgnet"
)

// WireGuardService is the panel's end of Beacle's own tunnel. Everything runs
// in-process: no system interface, no route, so nothing but this listener is
// reachable through it, and the listener serves nothing but /agent/ws. A peer
// is only ever one server, pinned to a /32 — WireGuard authenticates the
// source address, so the tunnel IP on a request is proof of which server sent
// it.
type WireGuardService struct {
	store *Store
	path  string
	priv  shared.WGKey
	pub   shared.WGKey

	mu      sync.Mutex
	tun     *wgnet.Tunnel
	http    *http.Server
	err     string
	serveWS func(http.ResponseWriter, *http.Request, *VPSEntry)
}

type wgKeyFile struct {
	PrivateKey string `json:"private_key"`
}

func NewWireGuardService(dataDir string, store *Store) (*WireGuardService, error) {
	w := &WireGuardService{store: store, path: filepath.Join(dataDir, "wireguard.json")}
	if b, err := os.ReadFile(w.path); err == nil {
		var f wgKeyFile
		if err := json.Unmarshal(b, &f); err == nil {
			w.priv, _ = shared.ParseWGKey(f.PrivateKey)
		}
	}
	if w.priv.IsZero() {
		k, err := shared.GenerateWGPrivateKey()
		if err != nil {
			return nil, err
		}
		b, _ := json.MarshalIndent(wgKeyFile{PrivateKey: k.String()}, "", "  ")
		if err := os.WriteFile(w.path, b, 0o600); err != nil {
			return nil, fmt.Errorf("wireguard: save key: %w", err)
		}
		w.priv = k
	}
	pub, err := w.priv.PublicKey()
	if err != nil {
		return nil, err
	}
	w.pub = pub
	return w, nil
}

func (w *WireGuardService) PublicKey() shared.WGKey { return w.pub }

// Start remembers the agent socket handler and brings the tunnel up if any
// server already uses it. A panel with only Tailscale servers never opens
// the UDP socket at all.
func (w *WireGuardService) Start(serveWS func(http.ResponseWriter, *http.Request, *VPSEntry)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.serveWS = serveWS
	for _, e := range w.store.ListEntries() {
		if e.HasWireGuardPeer() {
			if err := w.ensureUpLocked(); err != nil {
				log.Printf("wireguard: %v", err)
			}
			return
		}
	}
}

func (w *WireGuardService) ensureUpLocked() error {
	if w.tun != nil {
		return nil
	}
	backendIP := netip.MustParseAddr(shared.WGBackendTunnelIP)
	tun, err := wgnet.Up(wgnet.Config{PrivateKey: w.priv, Address: backendIP})
	if err != nil {
		w.err = err.Error()
		return err
	}
	ln, err := tun.Net.ListenTCPAddrPort(netip.AddrPortFrom(backendIP, shared.WGBackendPort))
	if err != nil {
		tun.Close()
		w.err = err.Error()
		return fmt.Errorf("listen in tunnel: %w", err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /agent/ws", w.handleAgentWS)
	w.http = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func(srv *http.Server) {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("wireguard: serve: %v", err)
		}
	}(w.http)
	w.tun = tun
	w.err = ""
	for _, e := range w.store.ListEntries() {
		if e.HasWireGuardPeer() {
			if err := w.setPeerLocked(&e); err != nil {
				log.Printf("wireguard: peer %s: %v", e.VPS.Name, err)
			}
		}
	}
	log.Printf("wireguard: up on udp/%d, agents reach %s:%d", tun.ListenPort(), shared.WGBackendTunnelIP, shared.WGBackendPort)
	return nil
}

func (w *WireGuardService) handleAgentWS(rw http.ResponseWriter, r *http.Request) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		http.Error(rw, "bad peer", http.StatusForbidden)
		return
	}
	entry := w.store.FindByTunnelIP(host)
	if entry == nil {
		http.Error(rw, "unknown peer", http.StatusForbidden)
		return
	}
	w.mu.Lock()
	serve := w.serveWS
	w.mu.Unlock()
	if serve == nil {
		http.Error(rw, "not ready", http.StatusServiceUnavailable)
		return
	}
	serve(rw, r, entry)
}

func (w *WireGuardService) setPeerLocked(e *VPSEntry) error {
	pub, err := shared.ParseWGKey(e.VPS.WGPublicKey)
	if err != nil {
		return fmt.Errorf("public key: %w", err)
	}
	psk, _ := shared.ParseWGKey(e.WGPresharedKey)
	tip, err := netip.ParseAddr(e.VPS.WGTunnelIP)
	if err != nil {
		return fmt.Errorf("tunnel ip: %w", err)
	}
	return w.tun.SetPeer(wgnet.Peer{
		PublicKey:    pub,
		PresharedKey: psk,
		Endpoint:     e.VPS.WGEndpoint,
		AllowedIP:    netip.PrefixFrom(tip, 32),
		Keepalive:    shared.WGKeepaliveSec,
	})
}

// SyncPeer (re)installs a server's peer, starting the tunnel on first use.
func (w *WireGuardService) SyncPeer(e *VPSEntry) error {
	if w == nil || e == nil || !e.HasWireGuardPeer() {
		return nil
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := w.ensureUpLocked(); err != nil {
		return err
	}
	return w.setPeerLocked(e)
}

// RemovePeer drops a server's key, cutting it off immediately.
func (w *WireGuardService) RemovePeer(publicKey string) {
	if w == nil {
		return
	}
	pub, err := shared.ParseWGKey(publicKey)
	if err != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.tun != nil {
		_ = w.tun.RemovePeer(pub)
	}
}

// AllocateTunnelIP picks the lowest free address in the tunnel subnet.
func (w *WireGuardService) AllocateTunnelIP() (string, error) {
	used := map[string]bool{shared.WGBackendTunnelIP: true}
	for _, e := range w.store.ListEntries() {
		if e.VPS.WGTunnelIP != "" {
			used[e.VPS.WGTunnelIP] = true
		}
	}
	prefix := netip.MustParsePrefix(shared.WGTunnelPrefix)
	for ip := prefix.Addr().Next().Next(); prefix.Contains(ip); ip = ip.Next() {
		if b := ip.As4(); b[3] == 0 || b[3] == 255 {
			continue
		}
		if !used[ip.String()] {
			return ip.String(), nil
		}
	}
	return "", errors.New("wireguard: tunnel subnet exhausted")
}

// JoinFor builds the token the install command carries. Only possible while
// the panel still holds the agent's private key, i.e. before first contact.
func (w *WireGuardService) JoinFor(e *VPSEntry) (shared.WGJoin, error) {
	if e.WGAgentKey == "" {
		return shared.WGJoin{}, errors.New("this server's key was already used; generate a new one")
	}
	port := shared.WGDefaultPort
	if ap, err := netip.ParseAddrPort(e.VPS.WGEndpoint); err == nil {
		port = int(ap.Port())
	}
	j := shared.WGJoin{
		PrivateKey:    e.WGAgentKey,
		PeerPublicKey: w.pub.String(),
		PresharedKey:  e.WGPresharedKey,
		Address:       e.VPS.WGTunnelIP,
		PeerAddress:   shared.WGBackendTunnelIP,
		ListenPort:    port,
		VPSID:         e.VPS.ID,
	}
	return j, j.Validate()
}

// LastHandshake reports when the server last completed a handshake; zero
// when never, or when the tunnel is not running.
func (w *WireGuardService) LastHandshake(publicKey string) time.Time {
	for _, p := range w.stats() {
		if p.PublicKey.String() == publicKey {
			return p.LastHandshake
		}
	}
	return time.Time{}
}

func (w *WireGuardService) stats() []wgnet.PeerStats {
	if w == nil {
		return nil
	}
	w.mu.Lock()
	tun := w.tun
	w.mu.Unlock()
	if tun == nil {
		return nil
	}
	st, _ := tun.Stats()
	return st
}

func (w *WireGuardService) Status() shared.WGStatus {
	w.mu.Lock()
	out := shared.WGStatus{Running: w.tun != nil, PublicKey: w.pub.String(), Error: w.err, Peers: []shared.WGPeerStatus{}}
	w.mu.Unlock()
	byKey := map[string]wgnet.PeerStats{}
	for _, p := range w.stats() {
		byKey[p.PublicKey.String()] = p
	}
	for _, e := range w.store.ListEntries() {
		if !e.HasWireGuardPeer() {
			continue
		}
		ps := shared.WGPeerStatus{
			VPSID:    e.VPS.ID,
			Name:     e.VPS.Name,
			Endpoint: e.VPS.WGEndpoint,
			TunnelIP: e.VPS.WGTunnelIP,
		}
		if st, ok := byKey[e.VPS.WGPublicKey]; ok {
			if st.Endpoint != "" {
				ps.Endpoint = st.Endpoint
			}
			if !st.LastHandshake.IsZero() {
				ps.LastHandshake = st.LastHandshake.Unix()
			}
			ps.RxBytes, ps.TxBytes = st.RxBytes, st.TxBytes
		}
		out.Peers = append(out.Peers, ps)
	}
	return out
}

func (w *WireGuardService) Close() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.http != nil {
		_ = w.http.Close()
	}
	if w.tun != nil {
		w.tun.Close()
		w.tun = nil
	}
}
