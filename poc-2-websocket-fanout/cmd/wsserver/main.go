//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"runtime"
	"time"

	"github.com/gorilla/websocket"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/ffwd-org/stg-seats-poc/poc-2-websocket-fanout/internal/conn"
	"github.com/ffwd-org/stg-seats-poc/poc-2-websocket-fanout/internal/hub"
)

const pocName = "poc2"

var (
	flagPort         int
	flagMetricsPort int

	activeConns = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "poc2_active_connections",
		Help: "Active WebSocket connections",
	})
	goroutineCount = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "poc2_goroutine_count",
		Help: "Go runtime goroutine count",
	})
	broadcastDuration = prometheus.NewHistogram(prometheus.HistogramOpts{
		Name:    "poc2_broadcast_duration_seconds",
		Help:    "Time to fan out a broadcast to all connections",
		Buckets: []float64{.001, .005, .01, .025, .05, .1, .25, .5, 1},
	})
	broadcastCount = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "poc2_broadcast_total",
		Help: "Total broadcast operations",
	})
)

func init() {
	prometheus.MustRegister(activeConns, goroutineCount, broadcastDuration, broadcastCount)
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // allow all origins in POC
	},
}

func main() {
	fs := flag.NewFlagSet("wsserver", flag.ContinueOnError)
	fs.IntVar(&flagPort, "port", 8080, "HTTP server port")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	h := hub.New()

	// Broadcast latency tracker
	h.BroadcastLatency = func(eventID string) func() {
		start := time.Now()
		return func() {
			broadcastDuration.Observe(time.Since(start).Seconds())
		}
	}

	go h.Run(ctx)
	go metricsReporter(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/ws/event/", handleWS(h))
	mux.HandleFunc("/broadcast/", handleBroadcast(h))
	mux.Handle("/metrics", promhttp.Handler())

	addr := fmt.Sprintf(":%d", flagPort)
	log.Printf("WebSocket server listening on %s", addr)

	metricsAddr := fmt.Sprintf(":%d", flagMetricsPort)
	go func() {
		log.Printf("Metrics server listening on %s", metricsAddr)
		log.Printf(http.ListenAndServe(metricsAddr, promhttp.Handler()))
	}()

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("server: %v", err)
	}
}

func handleWS(h *hub.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		eventID := r.URL.Path[len("/ws/event/"):]
		if eventID == "" {
			http.Error(w, "event ID required", http.StatusBadRequest)
			return
		}

		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("upgrade error: %v", err)
			return
		}

		c := conn.NewConn(ws)
		activeConns.Inc()
		goroutineCount.Set(float64(runtime.NumGoroutine()))

		h.JoinRoom(eventID, c)

		// Read loop — just drain incoming messages (pings, acks)
		go func() {
			defer func() {
				h.unregister <- c
				c.Close()
				activeConns.Dec()
				goroutineCount.Set(float64(runtime.NumGoroutine()))
			}()
			for {
				if _, _, err := c.ReadMessage(); err != nil {
					return
				}
			}
		}()
	}
}

func handleBroadcast(h *hub.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}

		eventID := r.URL.Path[len("/broadcast/"):]
		if eventID == "" {
			http.Error(w, "event ID required", http.StatusBadRequest)
			return
		}

		var payload map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			payload = map[string]interface{}{"ts": time.Now().Unix()}
		}

		msg, _ := json.Marshal(payload)
		n := h.BroadcastCount(eventID)
		broadcastCount.Inc()

		log.Printf("broadcast to %s (%d conns): %s", eventID, n, string(msg))
		fmt.Fprintf(w, `{"event":"%s","conns":%d}`, eventID, n)
	}
}

func metricsReporter(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			goroutineCount.Set(float64(runtime.NumGoroutine()))
		}
	}
}
