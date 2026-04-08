package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const pocName = "poc2-conngen"

// LatencyCollector is a thread-safe collector for latency samples.
type LatencyCollector struct {
	mu   sync.Mutex
	data []float64
}

func (l *LatencyCollector) Append(v float64) {
	l.mu.Lock()
	l.data = append(l.data, v)
	l.mu.Unlock()
}

func (l *LatencyCollector) Reset() []float64 {
	l.mu.Lock()
	d := l.data
	l.data = nil
	l.mu.Unlock()
	return d
}

var (
	flagTarget      string
	flagConnections int
	flagRampRate    int
	flagMetricsPort int
	flagSourceIPs   string

	connected    atomic.Int32
	messagesRcvd atomic.Int64
	latencies    = &LatencyCollector{}

	connectedGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "poc2_connections_connected",
		Help: "Currently connected WebSocket clients",
	})
	messagesCounter = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "poc2_messages_received_total",
		Help: "Total broadcast messages received",
	})
)

func init() {
	prometheus.MustRegister(connectedGauge, messagesCounter)
}

func main() {
	fs := flag.NewFlagSet("conngen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "ws://localhost:8080/ws/event/1", "WebSocket server URL")
	fs.IntVar(&flagConnections, "connections", 250000, "total connections to establish")
	fs.IntVar(&flagRampRate, "ramp-rate", 5000, "connections per second during ramp")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	fs.StringVar(&flagSourceIPs, "source-ips", "", "comma-separated source IPs for dialer binding")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	// Parse source IPs
	var sourceIPs []net.IP
	if flagSourceIPs != "" {
		for _, s := range strings.Split(flagSourceIPs, ",") {
			s = strings.TrimSpace(s)
			ip := net.ParseIP(s)
			if ip == nil {
				log.Fatalf("invalid source IP: %s", s)
			}
			sourceIPs = append(sourceIPs, ip)
		}
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		addr := fmt.Sprintf(":%d", flagMetricsPort)
		log.Printf("Metrics server listening on %s", addr)
		log.Fatal(http.ListenAndServe(addr, nil))
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	log.Printf("Connecting %d clients to %s at %d/sec", flagConnections, flagTarget, flagRampRate)

	// Start latency reporter
	go latencyReporter(ctx)

	var wg sync.WaitGroup
	delayPerConn := time.Second / time.Duration(flagRampRate)

	for i := 0; i < flagConnections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			var srcIP net.IP
			if len(sourceIPs) > 0 {
				srcIP = sourceIPs[id%len(sourceIPs)]
			}
			runClient(ctx, id, srcIP)
		}(i)

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

func runClient(ctx context.Context, id int, srcIP net.IP) {
	url := flagTarget

	dialer := websocket.Dialer{}
	if srcIP != nil {
		dialer.NetDialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
			localAddr := &net.TCPAddr{IP: srcIP}
			d := net.Dialer{LocalAddr: localAddr}
			return d.DialContext(ctx, network, addr)
		}
	}

	ws, _, err := dialer.DialContext(ctx, url, nil)
	if err != nil {
		log.Printf("[client %d] dial error: %v", id, err)
		return
	}
	defer ws.Close()

	connected.Add(1)
	connectedGauge.Inc()
	defer func() {
		connected.Add(-1)
		connectedGauge.Dec()
	}()

	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			return
		}
		messagesRcvd.Add(1)
		messagesCounter.Inc()

		// Record receive time for latency tracking
		if len(msg) > 0 {
			latencies.Append(float64(time.Now().UnixMilli()))
		}
	}
}

func latencyReporter(ctx context.Context) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			data := latencies.Reset()
			if len(data) == 0 {
				continue
			}
			sort.Float64s(data)
			n := len(data)
			p50 := data[int(math.Floor(float64(n)*0.50))]
			p99 := data[int(math.Floor(float64(n)*0.99))]
			log.Printf("latency samples=%d  p50=%.0fms  p99=%.0fms", n, p50, p99)
		}
	}
}
