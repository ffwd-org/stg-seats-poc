package conn

import (
	"context"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const writeDeadline = 5 * time.Second

// Conn wraps a websocket.Conn with a per-connection write mutex and deadline.
// This is the critical fix: individual WriteMessage calls must not block each other.
type Conn struct {
	ws   *websocket.Conn
	mu   sync.Mutex
	send chan []byte
}

func NewConn(ws *websocket.Conn) *Conn {
	return &Conn{
		ws:   ws,
		send: make(chan []byte, 256),
	}
}

// WriteMessage is safe for concurrent use — each call gets its own lock + deadline.
func (c *Conn) WriteMessage(msgType int, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ws.SetWriteDeadline(time.Now().Add(writeDeadline))
	return c.ws.WriteMessage(msgType, data)
}

// WriteJSON marshals and writes a JSON message with the same deadline protection.
func (c *Conn) WriteJSON(v interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ws.SetWriteDeadline(time.Now().Add(writeDeadline))
	return c.ws.WriteJSON(v)
}

// Close gracefully shuts down the connection.
func (c *Conn) Close() error {
	close(c.send)
	return c.ws.Close()
}

// SetReadDeadline sets the read deadline. Zero value = no deadline.
func (c *Conn) SetReadDeadline(t time.Time) error {
	return c.ws.SetReadDeadline(t)
}

// ReadMessage reads the next message. Caller is responsible for locking if needed.
func (c *Conn) ReadMessage() (int, []byte, error) {
	return c.ws.ReadMessage()
}
