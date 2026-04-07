//go:build ignore

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const pocName = "poc2-conngen"

var (
	flagTarget      string
	flagConnections int
	flagRampRate    int
	flagMetricsPort int

	connected   atomic.Int32
	messagesRcvd atomic.Int64
	latenciesMs atomic.Uint64Slice
	latMu       sync.Mutex
)

func init() {
	prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "poc2_connections_connected",
		Help: "Currently connected WebSocket clients",
	}).Add(0)
	prometheus.NewCounter(prometheus.CounterOpts{
		Name: "poc2_messages_received_total",
		Help: "Total broadcast messages received",
	})
}

func main() {
	fs := flag.NewFlagSet("conngen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "ws://localhost:8080/ws/event/1", "WebSocket server URL")
	fs.IntVar(&flagConnections, "connections", 10000, "total connections to establish")
	fs.IntVar(&flagRampRate, "ramp-rate", 5000, "connections per second during ramp")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		addr := fmt.Sprintf(":%d", flagMetricsPort)
		log.Printf("Metrics server listening on %s", addr)
		log.Printf(http.ListenAndServe(addr, nil))
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	log.Printf("Connecting %d clients to %s at %d/sec", flagConnections, flagTarget, flagRampRate)

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	var wg sync.WaitGroup
	delayPerConn := time.Second / time.Duration(flagRampRate)

	for i := 0; i < flagConnections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runClient(ctx, id)
		}(i)

		// Rate-limit connection establishment
		if i > 0 && i%flagRampRate == 0 {
			select {
			case <-ticker.C:
			case <-ctx.Done():
				return
			}
		}
		if delayPerConn > 0 {
			time.Sleep(delayPerConn)
		}

		if i%10000 == 0 && i > 0 {
			log.Printf("  connected: %d / %d", connected.Load(), flagConnections)
		}
	}

	wg.Wait()
	log.Printf("All %d clients connected. Holding...", connected.Load())
	log.Printf("Messages received: %d", messagesRcvd.Load())

	// Hold forever (or until context cancelled)
	<-ctx.Done()
}

func runClient(ctx context.Context, id int) {
	url := flagTarget
	if flagRampRate > 0 {
		// Each client gets its own event channel
		url = fmt.Sprintf("%s/%d", flagTarget, id%100) // spread across up to 100 channels
	}

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
		msgType, msg, err := ws.ReadMessage()
		if err != nil {
			return
		}
		messagesRcvd.Add(1)
		_ = msgType

		// Record receive time — for actual fan-out latency, compare to broadcast trigger time
		if len(msg) > 0 {
			latMu.Lock()
			latenciesMs.Append(uint64(time.Now().UnixMilli()))
			latMu.Unlock()
		}
	}
}
