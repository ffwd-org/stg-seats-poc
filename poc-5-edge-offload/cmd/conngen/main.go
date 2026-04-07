//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const pocName = "poc5-conngen"

var (
	flagTarget      string
	flagConnections int
	flagRampRate   int
	flagMetricsPort int

	connected     atomic.Int32
	messagesRcvd atomic.Int64
)

func main() {
	fs := flag.NewFlagSet("conngen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "ws://localhost:8000/connection/uni_subscribe", "Centrifugo WebSocket URL")
	fs.IntVar(&flagConnections, "connections", 10000, "total connections")
	fs.IntVar(&flagRampRate, "ramp-rate", 5000, "connections per second")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	log.Printf("Connecting %d clients to Centrifugo at %d/sec", flagConnections, flagRampRate)

	var wg sync.WaitGroup
	delayPerConn := time.Second / time.Duration(flagRampRate)

	for i := 0; i < flagConnections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runClient(ctx, id)
		}(i)

		if delayPerConn > 0 {
			time.Sleep(delayPerConn)
		}
	}

	wg.Wait()
	log.Printf("All %d clients connected. Holding...", connected.Load())
	<-ctx.Done()
}

func runClient(ctx context.Context, id int) {
	// Build Centrifugo connection URL with token (simplified — in prod use JWT)
	url := fmt.Sprintf("%s?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9", flagTarget)

	dialer := websocket.Dialer{}
	ws, _, err := dialer.DialContext(ctx, url, nil)
	if err != nil {
		log.Printf("[client %d] dial error: %v", id, err)
		return
	}
	defer ws.Close()

	connected.Add(1)
	defer connected.Add(-1)

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			return
		}
		messagesRcvd.Add(1)
		_ = msg // count only
	}
}

// Centrifugo uses JSON messages — a subscribe frame and then publishes:
// {"type": 1, "body": {"channel": "stg-seats:1", "data": {...}}}
type centrifugoMessage struct {
	Type int             `json:"type"`
	Body json.RawMessage `json:"body"`
}
