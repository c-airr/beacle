package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"sync"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

const (
	wsHandshakeTimeout = 30 * time.Second
	wsReadTimeout      = 90 * time.Second
	wsWriteTimeout     = 15 * time.Second
	pingInterval       = 20 * time.Second
	reconnectMin       = 1 * time.Second
	reconnectMax       = 30 * time.Second
)

// WSClient is the only transport to the backend: register, snapshots, commands, keepalive.
type WSClient struct {
	cfg      *Config
	api      *APIServer
	reporter *Reporter
}

func NewWSClient(cfg *Config, api *APIServer, reporter *Reporter) *WSClient {
	return &WSClient{cfg: cfg, api: api, reporter: reporter}
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
	for {
		registered, err := c.session()
		if err != nil {
			log.Printf("agent ws session ended: %v", err)
		}
		if registered {
			backoff = reconnectMin
		}
		log.Printf("agent ws reconnect in %s", backoff)
		time.Sleep(backoff)
		backoff *= 2
		if backoff > reconnectMax {
			backoff = reconnectMax
		}
	}
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

	dialer := websocket.Dialer{HandshakeTimeout: wsHandshakeTimeout}
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

	writeCh := make(chan []byte, 64)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var writeOnce sync.Once
	closeWrite := func() { writeOnce.Do(func() { close(writeCh) }) }
	defer closeWrite()

	sync := NewSyncEngine(c.cfg, c.reporter, writeCh)
	sync.SetPowerMode(powerMode)

	errCh := make(chan error, 4)
	go c.writePump(ctx, writeCh, writeText, writeControl, errCh)
	go func() { errCh <- c.readLoop(conn, writeCh, sync) }()
	go sync.Run(ctx)

	err = <-errCh
	cancel()
	closeWrite()
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
				return "", fmt.Errorf("register: %s", msg.Error)
			}
			return "", fmt.Errorf("register rejected")
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

func (c *WSClient) readLoop(conn *websocket.Conn, writeCh chan<- []byte, sync *SyncEngine) error {
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
