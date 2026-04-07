package hub

import (
	"context"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-2-websocket-fanout/internal/conn"
	"github.com/gorilla/websocket"
)

// Room is a named set of websocket connections (one per event).
type Room struct {
	ID    string
	Conns map[*conn.Conn]bool
	mu    sync.RWMutex
}

// Hub manages all rooms and broadcast operations.
type Hub struct {
	rooms map[string]*Room
	mu    sync.RWMutex

	connCount  int64
	register   chan *conn.Conn
	unregister chan *conn.Conn
	roomJoin   chan roomJoin

	// Optional latency tracker
	BroadcastLatency func(eventID string) func()
}

type roomJoin struct {
	EventID string
	C       *conn.Conn
}

func New() *Hub {
	return &Hub{
		rooms:      make(map[string]*Room),
		register:   make(chan *conn.Conn),
		unregister: make(chan *conn.Conn),
		roomJoin:   make(chan roomJoin),
	}
}

func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case j := <-h.roomJoin:
			h.addToRoom(j.EventID, j.C)
		case c := <-h.register:
			_ = c // global broadcast (no-op here; use JoinRoom for per-event)
		case c := <-h.unregister:
			h.removeConn(c)
		}
	}
}

// JoinRoom registers a connection to a specific event room.
func (h *Hub) JoinRoom(eventID string, c *conn.Conn) {
	h.roomJoin <- roomJoin{EventID: eventID, C: c}
}

// Broadcast sends a message to all connections in a room.
// Uses RLock — safe for concurrent broadcast calls.
// Returns time taken to fan out to all connections.
func (h *Hub) Broadcast(eventID string, message []byte) time.Duration {
	start := time.Now()

	if h.BroadcastLatency != nil {
		end := h.BroadcastLatency(eventID)
		defer end()
	}

	h.mu.RLock()
	room, ok := h.rooms[eventID]
	if !ok {
		h.mu.RUnlock()
		return 0
	}
	conns := make([]*conn.Conn, 0, len(room.Conns))
	for c := range room.Conns {
		conns = append(conns, c)
	}
	h.mu.RUnlock()

	var wg sync.WaitGroup
	for _, c := range conns {
		wg.Add(1)
		go func(sc *conn.Conn) {
			defer wg.Done()
			if err := sc.WriteMessage(websocket.TextMessage, message); err != nil {
				h.unregister <- sc
			}
		}(c)
	}
	wg.Wait()

	return time.Since(start)
}

// BroadcastCount returns how many connections would receive a broadcast.
func (h *Hub) BroadcastCount(eventID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if room, ok := h.rooms[eventID]; ok {
		return len(room.Conns)
	}
	return 0
}

// ConnCount returns total active connections.
func (h *Hub) ConnCount() int64 {
	return atomic.LoadInt64(&h.connCount)
}
