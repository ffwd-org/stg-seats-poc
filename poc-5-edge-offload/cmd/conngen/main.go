package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/websocket"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const pocName = "poc5-conngen"

var (
	flagTarget      string
	flagConnections int
	flagRampRate    int
	flagMetricsPort int
	flagJWTSecret   string
	flagChannel     string
	flagSourceIPs   string

	connected    atomic.Int32
	messagesRcvd atomic.Int64
	reconnects   atomic.Int64
	disconnects  atomic.Int64
)

func generateJWT(secret string, userID string) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": userID,
		"exp": time.Now().Add(24 * time.Hour).Unix(),
	})
	return token.SignedString([]byte(secret))
}

func main() {
	fs := flag.NewFlagSet("conngen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "ws://localhost:8000/connection/websocket", "Centrifugo WebSocket URL")
	fs.IntVar(&flagConnections, "connections", 250000, "total connections")
	fs.IntVar(&flagRampRate, "ramp-rate", 5000, "connections per second")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	fs.StringVar(&flagJWTSecret, "jwt-secret", "poc-secret-key-for-jwt", "JWT HMAC secret for Centrifugo auth")
	fs.StringVar(&flagChannel, "channel", "events:event-1", "Centrifugo channel to subscribe")
	fs.StringVar(&flagSourceIPs, "source-ips", "", "comma-separated source IPs to bind (optional)")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	// Serve Prometheus metrics and plain-text stats on /metrics
	mux := http.NewServeMux()
	mux.Handle("/metrics", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Emit custom plain-text counters before Prometheus metrics
		fmt.Fprintf(w, "connected %d\n", connected.Load())
		fmt.Fprintf(w, "messages %d\n", messagesRcvd.Load())
		fmt.Fprintf(w, "reconnects %d\n", reconnects.Load())
		fmt.Fprintf(w, "disconnects %d\n", disconnects.Load())
		fmt.Fprintln(w, "---")
		promhttp.Handler().ServeHTTP(w, r)
	}))
	go func() {
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), mux)
	}()

	// Parse source IPs for multi-IP connections (needed for >64K conns)
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
		log.Printf("Using %d source IPs for connections", len(sourceIPs))
	}

	log.Printf("Connecting %d clients to Centrifugo at %d/sec (channel=%s)", flagConnections, flagRampRate, flagChannel)

	// Periodic stats logger
	go func() {
		for {
			time.Sleep(10 * time.Second)
			log.Printf("stats: connected=%d messages=%d reconnects=%d disconnects=%d",
				connected.Load(), messagesRcvd.Load(), reconnects.Load(), disconnects.Load())
		}
	}()

	delayPerConn := time.Second / time.Duration(flagRampRate)

	for i := 0; i < flagConnections; i++ {
		go func(id int) {
			var srcIP net.IP
			if len(sourceIPs) > 0 {
				srcIP = sourceIPs[id%len(sourceIPs)]
			}
			runClient(id, srcIP)
		}(i)

		if delayPerConn > 0 {
			time.Sleep(delayPerConn)
		}
	}

	log.Printf("All %d client goroutines launched. Holding...", flagConnections)
	select {} // hold forever — clients reconnect internally
}

func runClient(id int, srcIP net.IP) {
	userID := fmt.Sprintf("user-%d", id)

	const (
		backoffInit = 100 * time.Millisecond
		backoffMul  = 1.5
		backoffMax  = 10 * time.Second
	)

	backoff := backoffInit

	for { // outer reconnection loop
		token, err := generateJWT(flagJWTSecret, userID)
		if err != nil {
			log.Printf("[client %d] jwt error: %v", id, err)
			return
		}

		dialer := websocket.Dialer{}
		if srcIP != nil {
			dialer.NetDial = func(network, addr string) (net.Conn, error) {
				localAddr := &net.TCPAddr{IP: srcIP}
				d := net.Dialer{LocalAddr: localAddr}
				return d.Dial(network, addr)
			}
		}

		ws, _, err := dialer.Dial(flagTarget, nil)
		if err != nil {
			log.Printf("[client %d] dial error (retry in %v): %v", id, backoff, err)
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffMul)
			if backoff > backoffMax {
				backoff = backoffMax
			}
			continue
		}

		// Send Centrifugo connect frame
		connectFrame := map[string]interface{}{
			"connect": map[string]interface{}{
				"token": token,
				"name":  "loadgen",
			},
			"id": 1,
		}
		if err := ws.WriteJSON(connectFrame); err != nil {
			log.Printf("[client %d] connect write error (retry in %v): %v", id, backoff, err)
			ws.Close()
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffMul)
			if backoff > backoffMax {
				backoff = backoffMax
			}
			continue
		}

		// Read connect response
		_, _, err = ws.ReadMessage()
		if err != nil {
			log.Printf("[client %d] connect read error (retry in %v): %v", id, backoff, err)
			ws.Close()
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffMul)
			if backoff > backoffMax {
				backoff = backoffMax
			}
			continue
		}

		// Send subscribe frame
		subscribeFrame := map[string]interface{}{
			"subscribe": map[string]interface{}{
				"channel": flagChannel,
			},
			"id": 2,
		}
		if err := ws.WriteJSON(subscribeFrame); err != nil {
			log.Printf("[client %d] subscribe write error (retry in %v): %v", id, backoff, err)
			ws.Close()
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffMul)
			if backoff > backoffMax {
				backoff = backoffMax
			}
			continue
		}

		// Read subscribe response
		_, _, err = ws.ReadMessage()
		if err != nil {
			log.Printf("[client %d] subscribe read error (retry in %v): %v", id, backoff, err)
			ws.Close()
			time.Sleep(backoff)
			backoff = time.Duration(float64(backoff) * backoffMul)
			if backoff > backoffMax {
				backoff = backoffMax
			}
			continue
		}

		// Successfully connected — reset backoff
		backoff = backoffInit
		connected.Add(1)

		// Inner read loop
		for {
			_, msg, err := ws.ReadMessage()
			if err != nil {
				// Connection lost
				disconnects.Add(1)
				connected.Add(-1)
				log.Printf("[client %d] disconnected: %v", id, err)
				break // break inner loop, retry outer loop
			}
			messagesRcvd.Add(1)
			_ = msg // count only
		}
		ws.Close()

		// Prepare for reconnection
		reconnects.Add(1)
		time.Sleep(backoff)
		backoff = time.Duration(float64(backoff) * backoffMul)
		if backoff > backoffMax {
			backoff = backoffMax
		}
	}
}

// Centrifugo bidirectional JSON protocol message
type centrifugoMessage struct {
	ID     int             `json:"id,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Push   json.RawMessage `json:"push,omitempty"`
}
