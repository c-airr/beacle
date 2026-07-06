package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"beacle/shared"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true }, // desktop app, local use
}

// Hub fans out WSMessage frames to all connected UI clients.
type Hub struct {
	mu      sync.Mutex
	clients map[*websocket.Conn]chan []byte
}

func NewHub() *Hub {
	return &Hub{clients: map[*websocket.Conn]chan []byte{}}
}

func (h *Hub) Broadcast(t shared.WSMessageType, payload any) {
	b, err := json.Marshal(shared.WSMessage{Type: t, Payload: payload})
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for conn, ch := range h.clients {
		select {
		case ch <- b:
		default: // slow client - drop frame instead of blocking everyone
			_ = conn
		}
	}
}

func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade: %v", err)
		return
	}
	ch := make(chan []byte, 64)
	h.mu.Lock()
	h.clients[conn] = ch
	h.mu.Unlock()

	// writer
	go func() {
		for msg := range ch {
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				return
			}
		}
	}()

	// reader (only to detect close / respond to pings)
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}
	h.mu.Lock()
	delete(h.clients, conn)
	h.mu.Unlock()
	close(ch)
	_ = conn.Close()
}
