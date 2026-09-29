package shared

// Built-in WireGuard transport. The backend and the agent each run a
// userspace WireGuard device inside their own process (no system interface,
// no kernel module), and the agent's existing WebSocket rides inside it.
// The backend initiates the handshake to the VPS's public UDP port, so the
// desktop may sit behind any NAT; only the VPS needs to be reachable.

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/netip"
	"strings"
	"time"
)

const (
	TransportTailscale = "tailscale"
	TransportWireGuard = "wireguard"

	// WGDefaultPort is the agent's UDP listen port. Not 51820 so a WireGuard
	// the user already runs on the box keeps its port.
	WGDefaultPort = 51931
	// The tunnel lives in isolated netstacks on both ends, so it can never
	// collide with the host's own networks.
	WGBackendTunnelIP = "10.87.0.1"
	WGTunnelPrefix    = "10.87.0.0/16"
	WGBackendPort     = 9930
	WGKeepaliveSec    = 25
	// A handshake older than this means the tunnel is gone, not just idle.
	WGHandshakeFresh = 3 * time.Minute
	// How long a trial switch from Tailscale may fail before the agent
	// goes back on its own.
	WGSwitchFallback = 10 * time.Minute
	// WGJoinPrefix versions the install token format.
	WGJoinPrefix = "bcwg1."
)

// WGKey is a Curve25519 key (private, public or preshared).
type WGKey [32]byte

func GenerateWGPrivateKey() (WGKey, error) {
	var k WGKey
	if _, err := rand.Read(k[:]); err != nil {
		return k, err
	}
	k.clamp()
	return k, nil
}

// GenerateWGPresharedKey is 32 random bytes, no clamping.
func GenerateWGPresharedKey() (WGKey, error) {
	var k WGKey
	_, err := rand.Read(k[:])
	return k, err
}

func (k *WGKey) clamp() {
	k[0] &= 248
	k[31] = (k[31] & 127) | 64
}

// PublicKey derives the public half of a private key.
func (k WGKey) PublicKey() (WGKey, error) {
	var pub WGKey
	priv, err := ecdh.X25519().NewPrivateKey(k[:])
	if err != nil {
		return pub, err
	}
	copy(pub[:], priv.PublicKey().Bytes())
	return pub, nil
}

func (k WGKey) IsZero() bool { return k == WGKey{} }

// String is the base64 form wg(8) prints and configs store.
func (k WGKey) String() string { return base64.StdEncoding.EncodeToString(k[:]) }

// Hex is the form the WireGuard UAPI (IpcSet) expects.
func (k WGKey) Hex() string { return hex.EncodeToString(k[:]) }

func ParseWGKey(s string) (WGKey, error) {
	var k WGKey
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(s))
	if err != nil || len(b) != len(k) {
		return k, fmt.Errorf("invalid WireGuard key")
	}
	copy(k[:], b)
	return k, nil
}

// ParseWGKeyHex reads the UAPI form back (IpcGet output).
func ParseWGKeyHex(s string) (WGKey, error) {
	var k WGKey
	b, err := hex.DecodeString(strings.TrimSpace(s))
	if err != nil || len(b) != len(k) {
		return k, fmt.Errorf("invalid WireGuard key")
	}
	copy(k[:], b)
	return k, nil
}

// WGJoin is everything an agent needs to bring up its end of the tunnel.
// It travels as one opaque token in the install command, so it is a secret:
// it carries the agent's private key.
type WGJoin struct {
	PrivateKey    string `json:"k"` // agent private key, base64
	PeerPublicKey string `json:"p"` // backend public key, base64
	PresharedKey  string `json:"s"` // base64
	Address       string `json:"a"` // agent tunnel IP
	PeerAddress   string `json:"b"` // backend tunnel IP
	ListenPort    int    `json:"l"`
	VPSID         string `json:"v"`
}

// BackendURL is where the agent's WebSocket goes once the tunnel is up.
func (j WGJoin) BackendURL() string {
	a, err := netip.ParseAddr(j.PeerAddress)
	if err != nil {
		return ""
	}
	return "http://" + netip.AddrPortFrom(a, WGBackendPort).String()
}

func (j WGJoin) Validate() error {
	if _, err := ParseWGKey(j.PrivateKey); err != nil {
		return fmt.Errorf("join token: private key: %w", err)
	}
	if _, err := ParseWGKey(j.PeerPublicKey); err != nil {
		return fmt.Errorf("join token: peer key: %w", err)
	}
	if j.PresharedKey != "" {
		if _, err := ParseWGKey(j.PresharedKey); err != nil {
			return fmt.Errorf("join token: preshared key: %w", err)
		}
	}
	if _, err := netip.ParseAddr(j.Address); err != nil {
		return fmt.Errorf("join token: bad address")
	}
	if _, err := netip.ParseAddr(j.PeerAddress); err != nil {
		return fmt.Errorf("join token: bad peer address")
	}
	if j.ListenPort <= 0 || j.ListenPort > 65535 {
		return fmt.Errorf("join token: bad port")
	}
	return nil
}

func (j WGJoin) Encode() string {
	data, _ := json.Marshal(j)
	return WGJoinPrefix + base64.RawURLEncoding.EncodeToString(data)
}

func DecodeWGJoin(s string) (WGJoin, error) {
	var j WGJoin
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, WGJoinPrefix) {
		return j, fmt.Errorf("not a Beacle WireGuard token")
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(s, WGJoinPrefix))
	if err != nil {
		return j, fmt.Errorf("join token: %w", err)
	}
	if err := json.Unmarshal(raw, &j); err != nil {
		return j, fmt.Errorf("join token: %w", err)
	}
	return j, j.Validate()
}

// IPClass says whether a direct WireGuard handshake to an address can work.
type IPClass string

const (
	IPPublic   IPClass = "public"
	IPCGNAT    IPClass = "cgnat"   // 100.64.0.0/10: carrier NAT or Tailscale
	IPPrivate  IPClass = "private" // RFC1918, ULA, link-local
	IPLoopback IPClass = "loopback"
	IPInvalid  IPClass = "invalid"
)

var cgnatPrefix = netip.MustParsePrefix("100.64.0.0/10")

func ClassifyIP(s string) IPClass {
	a, err := netip.ParseAddr(strings.TrimSpace(s))
	if err != nil {
		return IPInvalid
	}
	a = a.Unmap()
	switch {
	case a.IsLoopback():
		return IPLoopback
	case a.Is4() && cgnatPrefix.Contains(a):
		return IPCGNAT
	case a.IsPrivate(), a.IsLinkLocalUnicast(), a.IsUnspecified(), a.IsMulticast():
		return IPPrivate
	}
	return IPPublic
}

// ConnectivityProbe is the backend's answer to "which transport can reach
// this host": address class plus one ICMP ping. A failed ping is only a
// warning — many providers drop ICMP while UDP works fine.
type ConnectivityProbe struct {
	Host        string  `json:"host"`
	IP          string  `json:"ip"`
	Class       IPClass `json:"class"`
	PingOK      bool    `json:"ping_ok"`
	LatencyMs   float64 `json:"latency_ms,omitempty"`
	WireGuardOK bool    `json:"wireguard_ok"`
	Recommended string  `json:"recommended"` // TransportWireGuard | TransportTailscale
	Reason      string  `json:"reason,omitempty"`
}

// WGPeerStatus is one tunnel as the backend's device sees it.
type WGPeerStatus struct {
	VPSID         string `json:"vps_id"`
	Name          string `json:"name"`
	Endpoint      string `json:"endpoint"`
	TunnelIP      string `json:"tunnel_ip"`
	LastHandshake int64  `json:"last_handshake"` // unix seconds, 0 = never
	RxBytes       int64  `json:"rx_bytes"`
	TxBytes       int64  `json:"tx_bytes"`
}

type WGStatus struct {
	Running   bool           `json:"running"`
	PublicKey string         `json:"public_key"`
	Error     string         `json:"error,omitempty"`
	Peers     []WGPeerStatus `json:"peers"`
}

// TransportSwitchRequest is sent backend→agent over the current tunnel to
// move an existing agent onto WireGuard (Join) or back to Tailscale.
type TransportSwitchRequest struct {
	Transport  string `json:"transport"`
	Join       string `json:"join,omitempty"`
	BackendURL string `json:"backend_url,omitempty"` // Tailscale switch-back
}

type TransportStatus struct {
	Transport     string `json:"transport"`
	Pending       string `json:"pending,omitempty"` // transport being trialled
	FallbackUntil string `json:"fallback_until,omitempty"`
}
