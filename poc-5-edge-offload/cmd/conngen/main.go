package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
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

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	log.Printf("Connecting %d clients to Centrifugo at %d/sec (channel=%s)", flagConnections, flagRampRate, flagChannel)

	var wg sync.WaitGroup
	delayPerConn := time.Second / time.Duration(flagRampRate)

	for i := 0; i < flagConnections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runClient(id)
		}(i)

		if delayPerConn > 0 {
			time.Sleep(delayPerConn)
		}
	}

	wg.Wait()
	log.Printf("All %d clients connected. Holding...", connected.Load())
	select {} // hold forever
}

func runClient(id int) {
	userID := fmt.Sprintf("user-%d", id)
	token, err := generateJWT(flagJWTSecret, userID)
	if err != nil {
		log.Printf("[client %d] jwt error: %v", id, err)
		return
	}

	dialer := websocket.Dialer{}
	ws, _, err := dialer.Dial(flagTarget, nil)
	if err != nil {
		log.Printf("[client %d] dial error: %v", id, err)
		return
	}
	defer ws.Close()

	// Send Centrifugo connect frame
	connectFrame := map[string]interface{}{
		"connect": map[string]interface{}{
			"token": token,
			"name":  "loadgen",
		},
		"id": 1,
	}
	if err := ws.WriteJSON(connectFrame); err != nil {
		log.Printf("[client %d] connect write error: %v", id, err)
		return
	}

	// Read connect response
	_, _, err = ws.ReadMessage()
	if err != nil {
		log.Printf("[client %d] connect read error: %v", id, err)
		return
	}

	// Send subscribe frame
	subscribeFrame := map[string]interface{}{
		"subscribe": map[string]interface{}{
			"channel": flagChannel,
		},
		"id": 2,
	}
	if err := ws.WriteJSON(subscribeFrame); err != nil {
		log.Printf("[client %d] subscribe write error: %v", id, err)
		return
	}

	// Read subscribe response
	_, _, err = ws.ReadMessage()
	if err != nil {
		log.Printf("[client %d] subscribe read error: %v", id, err)
		return
	}

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

// Centrifugo bidirectional JSON protocol message
type centrifugoMessage struct {
	ID     int             `json:"id,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Push   json.RawMessage `json:"push,omitempty"`
}
