package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
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
	flagPort        int
	flagMetricsPort int
	flagReadBuffer  int
	flagWriteBuffer int

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
	broadcastCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "poc2_broadcast_total",
		Help: "Total broadcast operations",
	})
	droppedConns = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "poc2_dropped_connections_total",
		Help: "Total dropped WebSocket connections",
	})
)

func init() {
	prometheus.MustRegister(activeConns, goroutineCount, broadcastDuration, broadcastCounter, droppedConns)
}

func main() {
	fs := flag.NewFlagSet("wsserver", flag.ContinueOnError)
	fs.IntVar(&flagPort, "port", 8080, "HTTP server port")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	fs.IntVar(&flagReadBuffer, "read-buffer", 1024, "WebSocket read buffer size in bytes")
	fs.IntVar(&flagWriteBuffer, "write-buffer", 1024, "WebSocket write buffer size in bytes")
	if err := fs.Parse(os.Args[1:]); err != nil {
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

	upgrader := websocket.Upgrader{
		ReadBufferSize:  flagReadBuffer,
		WriteBufferSize: flagWriteBuffer,
		CheckOrigin: func(r *http.Request) bool {
			return true // allow all origins in POC
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws/event/", handleWS(h, &upgrader))
	mux.HandleFunc("/broadcast/", handleBroadcast(h))
	mux.Handle("/metrics", promhttp.Handler())

	addr := fmt.Sprintf(":%d", flagPort)
	log.Printf("WebSocket server listening on %s", addr)

	metricsAddr := fmt.Sprintf(":%d", flagMetricsPort)
	go func() {
		log.Printf("Metrics server listening on %s", metricsAddr)
		log.Fatal(http.ListenAndServe(metricsAddr, promhttp.Handler()))
	}()

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal("server: ", err)
	}
}

func handleWS(h *hub.Hub, upgrader *websocket.Upgrader) http.HandlerFunc {
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
				h.Unregister(c)
				c.Close()
				activeConns.Dec()
				droppedConns.Inc()
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

		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		if len(body) == 0 {
			body = []byte(fmt.Sprintf(`{"ts":%d}`, time.Now().Unix()))
		}

		n := h.BroadcastCount(eventID)
		dur := h.Broadcast(eventID, body)
		broadcastCounter.Inc()

		log.Printf("broadcast to %s (%d conns): %s [%v]", eventID, n, string(body), dur)
		fmt.Fprintf(w, `{"event":"%s","conns":%d,"duration_ms":%.2f}`, eventID, n, dur.Seconds()*1000)
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
