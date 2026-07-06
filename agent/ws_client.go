package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"time"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

// WSClient maintains an outbound WebSocket to the backend. Reports and command
// responses flow over this single connection (CGNAT-safe, no inbound ports).
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
	for {
		if err := c.session(); err != nil {
			log.Printf("agent ws disconnected: %v (reconnect in 5s)", err)
		}
		time.Sleep(5 * time.Second)
	}
}

func (c *WSClient) session() error {
	wsURL, err := agentWSURL(c.cfg.BackendURL)
	if err != nil {
		return err
	}
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+c.cfg.Token)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, hdr)
	if err != nil {
		return err
	}
	defer conn.Close()
	log.Printf("agent ws connected to %s", wsURL)

	writeCh := make(chan []byte, 32)
	errCh := make(chan error, 3)

	go func() {
		for msg := range writeCh {
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				errCh <- err
				return
			}
		}
	}()

	go func() { errCh <- c.readLoop(conn, writeCh) }()
	go func() {
		errCh <- c.reportLoop(writeCh, time.Duration(c.cfg.ReportInterval)*time.Second)
	}()

	err = <-errCh
	close(writeCh)
	return err
}

func (c *WSClient) readLoop(conn *websocket.Conn, writeCh chan<- []byte) error {
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		var msg shared.AgentWSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("ws bad frame: %v", err)
			continue
		}
		if msg.Type != shared.AgentWSCommand || msg.Command == nil {
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
				ID:         cmd.ID,
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
	}
}

func (c *WSClient) reportLoop(writeCh chan<- []byte, interval time.Duration) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	send := func() error {
		rep := c.reporter.BuildReport()
		out, err := json.Marshal(shared.AgentWSMessage{
			Type:   shared.AgentWSReport,
			Report: &rep,
		})
		if err != nil {
			return err
		}
		select {
		case writeCh <- out:
			return nil
		default:
			return fmt.Errorf("ws write buffer full")
		}
	}
	if err := send(); err != nil {
		return err
	}
	for range ticker.C {
		if err := send(); err != nil {
			return err
		}
	}
	return nil
}
