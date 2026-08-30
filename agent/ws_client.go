package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

const (
	// The backend is the desktop panel: it is down whenever the app is closed,
	// and a dial at that moment either gets refused instantly or (Tailscale peer
	// asleep) hangs until it times out. Both paths have to stay cheap, because
	// the delay between "user opens the panel" and "server shows data" is
	// exactly one of these retries.
	// Measured against a real outage: a relayed Tailscale link dies silently,
	// and recovery cost 87s made up almost entirely of these two constants —
	// 35s to notice, then four dials that each hung for the full 10s because
	// the SYN went nowhere. Halving both roughly halves the outage.
	//
	// The floor is set by the ping interval: the read timeout has to survive a
	// couple of missed pongs on a laggy relay, or a healthy link gets torn
	// down for a hiccup and reconnects for no reason.
	wsHandshakeTimeout = 6 * time.Second
	wsReadTimeout      = 22 * time.Second // two missed pings plus slack
	wsWriteTimeout     = 10 * time.Second
	pingInterval       = 8 * time.Second

	reconnectMin = 1 * time.Second
	reconnectMax = 5 * time.Second
	// Registration refused is a configuration problem, not a transport one —
	// retrying it every few seconds only spams both sides.
	reconnectRejected = 30 * time.Second
)

// registerRejected marks a backend that answered but refused this agent, so the
// reconnect loop can back off differently than for an unreachable backend.
type registerRejected struct{ msg string }

func (e *registerRejected) Error() string { return e.msg }

// WSClient is the only transport to the backend: register, snapshots, commands, keepalive.
type WSClient struct {
	cfg      *Config
	api      *APIServer
	reporter *Reporter

	// offline holds samples taken while the panel was unreachable. It belongs
	// to the client rather than a session because its whole purpose is to
	// outlive sessions.
	offline *OfflineBuffer

	// connected is true only between register_ack and the end of that session.
	// The sampler reads it to decide whether the backend is already recording
	// this minute or whether it has to be kept here.
	connectedMu sync.RWMutex
	connected   bool
}

func NewWSClient(cfg *Config, api *APIServer, reporter *Reporter) *WSClient {
	return &WSClient{
		cfg:      cfg,
		api:      api,
		reporter: reporter,
		offline:  NewOfflineBuffer(cfg.StateDir()),
	}
}

func (c *WSClient) setConnected(v bool) {
	c.connectedMu.Lock()
	c.connected = v
	c.connectedMu.Unlock()
}

func (c *WSClient) isConnected() bool {
	c.connectedMu.RLock()
	defer c.connectedMu.RUnlock()
	return c.connected
}

// sampleOffline records one sample per interval whenever the panel is not
// listening. Deliberately outside the session: sessions end every time the
// laptop sleeps, and that is exactly when this has to keep running.
//
// Sampling is skipped while connected — the backend is already recording from
// the live snapshots, and writing here too would only produce duplicates for
// it to discard.
func (c *WSClient) sampleOffline(ctx context.Context) {
	t := time.NewTicker(offlineSampleInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if c.isConnected() {
				continue
			}
			m, err := c.reporter.Metrics()
			if err != nil {
				continue
			}
			if err := c.offline.Append(shared.SampleFrom(m)); err != nil {
				// A full or read-only disk is worth one line in the log, not a
				// line a minute for as long as the panel stays shut.
				log.Printf("offline sample not stored: %v", err)
			}
		}
	}
}

// flushOffline hands over everything recorded while the panel was away, in
// chunks, dropping each only once it has gone out. A drop part-way leaves the
// rest on disk for the next session rather than losing it.
func (c *WSClient) flushOffline(sync *SyncEngine) {
	samples, err := c.offline.Load()
	if err != nil || len(samples) == 0 {
		return
	}
	sent := 0
	for _, chunk := range chunkSamples(samples, offlineChunkSize) {
		if err := sync.sendBackfill(chunk); err != nil {
			break
		}
		// Only drop what actually left. The backend keeps one sample a minute
		// and ignores the rest, so re-sending a chunk after a mid-flush drop is
		// harmless; losing one is not.
		if err := c.offline.DropUpTo(chunk[len(chunk)-1].At); err != nil {
			break
		}
		sent += len(chunk)
	}
	if sent > 0 {
		log.Printf("handed over %d samples recorded while the panel was away", sent)
	}
}

func agentWSURL(backend string) (string, error) {
	u, err := url.Parse(backend)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("unsupported backend URL scheme %q", u.Scheme)
	}
	u.Path = "/agent/ws"
	u.RawQuery = ""
	return u.String(), nil
}

func (c *WSClient) Run() {
	backoff := reconnectMin
	var lastErr string
	var repeats int

	// Runs for the life of the agent, not the life of a session: the samples it
	// takes are precisely the ones no session was there to send.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go c.sampleOffline(ctx)

	for {
		registered, err := c.session()

		var rejected *registerRejected
		switch {
		case registered:
			// The session got as far as register_ack, so the backend is real and
			// healthy; whatever ended it (panel restart, laptop sleeping, network
			// blip) deserves an immediate retry.
			backoff = reconnectMin
		case errors.As(err, &rejected):
			backoff = reconnectRejected
		default:
			backoff *= 2
			if backoff > reconnectMax {
				backoff = reconnectMax
			}
		}

		// While the panel is closed this loop runs every few seconds for hours.
		// Log the first failure of a kind, then stay quiet until it changes.
		msg := "connection closed"
		if err != nil {
			msg = err.Error()
		}
		if msg != lastErr {
			log.Printf("agent ws session ended: %s (retry in %s)", msg, backoff)
			lastErr, repeats = msg, 0
		} else if repeats++; repeats%60 == 0 {
			log.Printf("agent ws still failing: %s (%d attempts)", msg, repeats)
		}

		time.Sleep(withJitter(backoff))
	}
}

// withJitter spreads reconnects so a fleet of agents does not hit the backend
// in lockstep after it comes back up.
func withJitter(d time.Duration) time.Duration {
	if d <= 0 {
		return reconnectMin
	}
	spread := int64(d / 4)
	if spread <= 0 {
		return d
	}
	return d - time.Duration(spread) + time.Duration(rand.Int63n(2*spread))
}

// session returns registered=true once register_ack was received (backoff should reset).
func (c *WSClient) session() (registered bool, err error) {
	wsURL, err := agentWSURL(c.cfg.BackendURL)
	if err != nil {
		return false, err
	}
	hdr := http.Header{}
	if c.cfg.Token != "" {
		hdr.Set("Authorization", "Bearer "+c.cfg.Token)
	}

	dialer := websocket.Dialer{
		HandshakeTimeout: wsHandshakeTimeout,
		NetDialContext: (&net.Dialer{
			Timeout: wsHandshakeTimeout,
			// The panel machine can drop off the tailnet without closing
			// anything; keepalives make a half-open socket surface as an error
			// instead of hanging on a read.
			KeepAlive: 15 * time.Second,
		}).DialContext,
	}
	conn, _, err := dialer.Dial(wsURL, hdr)
	if err != nil {
		return false, err
	}
	defer conn.Close()

	var writeMu sync.Mutex
	writeControl := func(messageType int, data []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		deadline := time.Now().Add(wsWriteTimeout)
		_ = conn.SetWriteDeadline(deadline)
		return conn.WriteControl(messageType, data, deadline)
	}
	writeText := func(data []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
		return conn.WriteMessage(websocket.TextMessage, data)
	}

	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
	})
	conn.SetPingHandler(func(appData string) error {
		if err := writeControl(websocket.PongMessage, []byte(appData)); err != nil {
			return err
		}
		return conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
	})

	powerMode, err := c.handshake(conn, writeText)
	if err != nil {
		return false, err
	}
	registered = true
	log.Printf("agent ws connected to %s (vps %s, mode %s)", wsURL, c.cfg.VPSID, powerMode)

	// From here the backend is recording again, so the sampler stands down
	// until this session ends.
	c.setConnected(true)
	defer c.setConnected(false)

	writeCh := make(chan []byte, 64)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// writeCh is deliberately never closed. It used to be, and closing a channel
	// that several goroutines are still writing to is a panic waiting for the
	// right millisecond: a push loop that had already passed its context check
	// would land its send on a channel closed a moment later, and the agent died
	// with "send on closed channel" every time a session dropped mid-push.
	//
	// Cancelling the context is enough. writePump returns on ctx.Done, senders
	// select on it alongside the send, and an abandoned buffer is garbage like
	// anything else.
	sync := NewSyncEngine(c.cfg, c.reporter, writeCh)
	sync.SetPowerMode(powerMode)

	errCh := make(chan error, 4)
	go c.writePump(ctx, writeCh, writeText, writeControl, errCh)
	go func() { errCh <- c.readLoop(ctx, conn, writeCh, sync) }()
	go sync.Run(ctx)

	// Hand over the gap before anything else fills the pipe, so a panel opened
	// after a night away draws the whole night rather than filling in from the
	// moment it happened to start.
	go c.flushOffline(sync)

	err = <-errCh
	cancel()
	return registered, err
}

func (c *WSClient) handshake(conn *websocket.Conn, writeText func([]byte) error) (shared.PowerMode, error) {
	reg, err := json.Marshal(shared.AgentWSMessage{
		Type:     shared.AgentWSRegister,
		Register: ptr(c.reporter.RegisterRequest()),
	})
	if err != nil {
		return "", err
	}
	if err := writeText(reg); err != nil {
		return "", err
	}

	_ = conn.SetReadDeadline(time.Now().Add(wsHandshakeTimeout))
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return "", err
		}
		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case shared.AgentWSRegisterAck:
			if msg.RegisterAck == nil {
				return "", fmt.Errorf("empty register_ack")
			}
			c.reporter.ApplyRegisterAck(*msg.RegisterAck)
			mode := msg.RegisterAck.PowerMode
			if mode == "" {
				mode = shared.PowerModeActive
			}
			_ = conn.SetReadDeadline(time.Now().Add(wsReadTimeout))
			return mode, nil
		case shared.AgentWSError:
			if msg.Error != "" {
				return "", &registerRejected{msg: "register: " + msg.Error}
			}
			return "", &registerRejected{msg: "register rejected"}
		default:
		}
	}
}

func (c *WSClient) writePump(
	ctx context.Context,
	writeCh <-chan []byte,
	writeText func([]byte) error,
	writeControl func(int, []byte) error,
	errCh chan<- error,
) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-writeCh:
			if !ok {
				return
			}
			if err := writeText(msg); err != nil {
				errCh <- err
				return
			}
		case <-ticker.C:
			if err := writeControl(websocket.PingMessage, []byte("ping")); err != nil {
				errCh <- err
				return
			}
		}
	}
}

func (c *WSClient) readLoop(ctx context.Context, conn *websocket.Conn, writeCh chan<- []byte, sync *SyncEngine) error {
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		_ = conn.SetReadDeadline(time.Now().Add(wsReadTimeout))

		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("ws bad frame: %v", err)
			continue
		}
		switch msg.Type {
		case shared.AgentWSCommand:
			if msg.Command == nil {
				continue
			}
			cmd := msg.Command
			var body []byte
			if len(cmd.Body) > 0 {
				body = []byte(cmd.Body)
			}
			code, resp := c.api.Dispatch(cmd.Method, cmd.Path, body)
			out, err := json.Marshal(shared.AgentWSMessage{
				Type: shared.AgentWSCommandResult,
				Result: &shared.AgentCommandResult{
					RequestID:  cmd.RequestID,
					StatusCode: code,
					Body:       json.RawMessage(resp),
				},
			})
			if err != nil {
				continue
			}
			select {
			case writeCh <- out:
			case <-ctx.Done():
				return ctx.Err() // session is finished; nobody is reading this
			default:
				log.Printf("ws write buffer full, dropping command result")
			}
			if isMutatingMethod(cmd.Method) && code >= 200 && code < 300 {
				sync.RequestRefresh()
			}
		case shared.AgentWSPowerMode:
			mode := msg.Mode
			if mode == "" {
				mode = shared.PowerModeActive
			}
			sync.SetPowerMode(mode)
		case shared.AgentWSRefresh:
			sync.RequestRefresh()
		case shared.AgentWSHeartbeat:
			// One-way keepalive from older peers — do not echo.
		case shared.AgentWSCommandResult, shared.AgentWSRegisterAck,
			shared.AgentWSMetrics, shared.AgentWSDockerSnapshot, shared.AgentWSSystemdSnapshot,
			shared.AgentWSPortsSnapshot, shared.AgentWSProxySnapshot:
			// ignore agent-originated / stale
		}
	}
}

func isMutatingMethod(method string) bool {
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	default:
		return false
	}
}

func ptr[T any](v T) *T { return &v }
