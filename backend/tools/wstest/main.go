// Quick manual test: connect to /ws and print the first few frames.
package main

import (
	"fmt"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	c, _, err := websocket.DefaultDialer.Dial("ws://127.0.0.1:8930/ws", nil)
	if err != nil {
		fmt.Println("dial error:", err)
		return
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	for i := 0; i < 3; i++ {
		_, msg, err := c.ReadMessage()
		if err != nil {
			fmt.Println("read error:", err)
			return
		}
		s := string(msg)
		if len(s) > 160 {
			s = s[:160] + "..."
		}
		fmt.Printf("frame %d: %s\n", i+1, s)
	}
	fmt.Println("WS_OK")
}
