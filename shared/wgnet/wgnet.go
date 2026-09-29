// Package wgnet runs a WireGuard device entirely inside the process: a
// userspace netstack instead of a system interface, and a single-socket UDP
// bind. Only the process that owns the Tunnel can use it — nothing else on
// the machine sees a route into the tunnel.
package wgnet

import (
	"bufio"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"beacle/shared"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// DefaultMTU leaves room for WireGuard's overhead on a 1500-byte path.
const DefaultMTU = 1420

type Config struct {
	PrivateKey shared.WGKey
	ListenPort int // 0 picks a random port (the side that only dials out)
	Address    netip.Addr
	MTU        int
}

type Peer struct {
	PublicKey    shared.WGKey
	PresharedKey shared.WGKey
	Endpoint     string // ip:port; empty for a peer that dials us
	AllowedIP    netip.Prefix
	Keepalive    int
}

type PeerStats struct {
	PublicKey     shared.WGKey
	Endpoint      string
	LastHandshake time.Time
	RxBytes       int64
	TxBytes       int64
}

type Tunnel struct {
	Net  *netstack.Net
	dev  *device.Device
	bind *udpBind
}

func Up(cfg Config) (*Tunnel, error) {
	if !cfg.Address.IsValid() {
		return nil, errors.New("wgnet: no tunnel address")
	}
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = DefaultMTU
	}
	tunDev, tnet, err := netstack.CreateNetTUN([]netip.Addr{cfg.Address}, nil, mtu)
	if err != nil {
		return nil, fmt.Errorf("wgnet: netstack: %w", err)
	}
	bind := &udpBind{}
	logger := &device.Logger{
		Verbosef: device.DiscardLogf,
		Errorf: func(format string, args ...any) {
			msg := fmt.Sprintf(format, args...)
			// The agent side never knows the panel's address: it waits to be
			// handshaken, and every packet queued until then says so.
			if strings.Contains(msg, "no known endpoint for peer") {
				return
			}
			log.Printf("wireguard: %s", msg)
		},
	}
	dev := device.NewDevice(tunDev, bind, logger)
	uapi := fmt.Sprintf("private_key=%s\nlisten_port=%d\n", cfg.PrivateKey.Hex(), cfg.ListenPort)
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, fmt.Errorf("wgnet: configure: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, fmt.Errorf("wgnet: up: %w", err)
	}
	return &Tunnel{Net: tnet, dev: dev, bind: bind}, nil
}

func (t *Tunnel) Close() { t.dev.Close() }

// ListenPort is the UDP port actually bound.
func (t *Tunnel) ListenPort() int { return t.bind.port() }

// SetPeer adds or replaces one peer.
func (t *Tunnel) SetPeer(p Peer) error {
	var b strings.Builder
	fmt.Fprintf(&b, "public_key=%s\n", p.PublicKey.Hex())
	if !p.PresharedKey.IsZero() {
		fmt.Fprintf(&b, "preshared_key=%s\n", p.PresharedKey.Hex())
	}
	if p.Endpoint != "" {
		fmt.Fprintf(&b, "endpoint=%s\n", p.Endpoint)
	}
	fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", p.Keepalive)
	b.WriteString("replace_allowed_ips=true\n")
	if p.AllowedIP.IsValid() {
		fmt.Fprintf(&b, "allowed_ip=%s\n", p.AllowedIP)
	}
	return t.dev.IpcSet(b.String())
}

func (t *Tunnel) RemovePeer(pub shared.WGKey) error {
	return t.dev.IpcSet(fmt.Sprintf("public_key=%s\nremove=true\n", pub.Hex()))
}

func (t *Tunnel) Stats() ([]PeerStats, error) {
	raw, err := t.dev.IpcGet()
	if err != nil {
		return nil, err
	}
	var out []PeerStats
	var cur *PeerStats
	var sec, nsec int64
	flush := func() {
		if cur != nil {
			if sec > 0 {
				cur.LastHandshake = time.Unix(sec, nsec)
			}
			out = append(out, *cur)
		}
	}
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		switch k {
		case "public_key":
			flush()
			key, err := shared.ParseWGKeyHex(v)
			if err != nil {
				cur = nil
				continue
			}
			cur = &PeerStats{PublicKey: key}
			sec, nsec = 0, 0
		case "endpoint":
			if cur != nil {
				cur.Endpoint = v
			}
		case "last_handshake_time_sec":
			sec, _ = strconv.ParseInt(v, 10, 64)
		case "last_handshake_time_nsec":
			nsec, _ = strconv.ParseInt(v, 10, 64)
		case "rx_bytes":
			if cur != nil {
				cur.RxBytes, _ = strconv.ParseInt(v, 10, 64)
			}
		case "tx_bytes":
			if cur != nil {
				cur.TxBytes, _ = strconv.ParseInt(v, 10, 64)
			}
		}
	}
	flush()
	return out, nil
}

// udpBind is a minimal conn.Bind: one dual-stack socket and one packet per
// call. The stock bind preallocates 128 batch buffers of 64 KiB per address
// family; a control channel carrying metrics and commands never needs that,
// and on a small VPS it would dwarf the rest of the agent.
type udpBind struct {
	mu   sync.Mutex
	conn *net.UDPConn
}

type endpoint struct{ ap netip.AddrPort }

func (e *endpoint) ClearSrc()           {}
func (e *endpoint) SrcToString() string { return "" }
func (e *endpoint) DstToString() string { return e.ap.String() }
func (e *endpoint) DstToBytes() []byte  { b, _ := e.ap.MarshalBinary(); return b }
func (e *endpoint) DstIP() netip.Addr   { return e.ap.Addr() }
func (e *endpoint) SrcIP() netip.Addr   { return netip.Addr{} }

var (
	_ conn.Bind     = (*udpBind)(nil)
	_ conn.Endpoint = (*endpoint)(nil)
)

func (b *udpBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	c, err := net.ListenUDP("udp", &net.UDPAddr{Port: int(port)})
	if err != nil {
		return nil, 0, err
	}
	b.conn = c
	recv := func(bufs [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		for {
			n, ap, err := c.ReadFromUDPAddrPort(bufs[0])
			if err == nil {
				sizes[0] = n
				eps[0] = &endpoint{netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port())}
				return 1, nil
			}
			if errors.Is(err, net.ErrClosed) {
				return 0, net.ErrClosed
			}
			// Windows reports an ICMP port-unreachable from an earlier send
			// as a read error. The device would treat it as fatal and stop
			// receiving for good, so swallow anything that is not a close.
			time.Sleep(10 * time.Millisecond)
		}
	}
	return []conn.ReceiveFunc{recv}, uint16(c.LocalAddr().(*net.UDPAddr).Port), nil
}

func (b *udpBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn == nil {
		return nil
	}
	err := b.conn.Close()
	b.conn = nil
	return err
}

func (b *udpBind) port() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.conn == nil {
		return 0
	}
	return b.conn.LocalAddr().(*net.UDPAddr).Port
}

func (b *udpBind) SetMark(uint32) error { return nil }

func (b *udpBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	b.mu.Lock()
	c := b.conn
	b.mu.Unlock()
	if c == nil {
		return net.ErrClosed
	}
	e, ok := ep.(*endpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	for _, buf := range bufs {
		if _, err := c.WriteToUDPAddrPort(buf, e.ap); err != nil {
			return err
		}
	}
	return nil
}

func (b *udpBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	if err != nil {
		return nil, err
	}
	return &endpoint{netip.AddrPortFrom(ap.Addr().Unmap(), ap.Port())}, nil
}

func (b *udpBind) BatchSize() int { return 1 }
