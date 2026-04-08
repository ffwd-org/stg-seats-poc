package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// CentrifugoPublisher is a stateless Go backend that publishes to Centrifugo.
// It holds NO WebSocket connections — Centrifugo handles all 250K clients.
type CentrifugoPublisher struct {
	apiURL string
	token  string
	client *http.Client
}

func NewCentrifugoPublisher(apiURL, token string) *CentrifugoPublisher {
	return &CentrifugoPublisher{
		apiURL: apiURL,
		token:  token,
		client: &http.Client{Timeout: 5 * time.Second},
	}
}

// Publish sends a message to a Centrifugo channel via the server-side API.
func (p *CentrifugoPublisher) Publish(ctx context.Context, channel string, data interface{}) error {
	payload := map[string]interface{}{
		"method": "publish",
		"params": map[string]interface{}{
			"channel": channel,
			"data":    data,
		},
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.apiURL+"/api/publish", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "apikey "+p.token)

	resp, err := p.client.Do(req)
	if err != nil {
		return fmt.Errorf("centrifugo publish: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("centrifugo returned %d", resp.StatusCode)
	}
	return nil
}

var (
	flagCentrifugoURL string
	flagCentrifugoKey string
	flagPort          int
	flagChannel       string
)

func main() {
	fs := flag.NewFlagSet("gowspublisher", flag.ContinueOnError)
	fs.StringVar(&flagCentrifugoURL, "centrifugo-url", "http://localhost:8000", "Centrifugo base URL")
	fs.StringVar(&flagCentrifugoKey, "centrifugo-key", "poc-api-key", "Centrifugo API key")
	fs.IntVar(&flagPort, "port", 8080, "Go publisher HTTP port")
	fs.StringVar(&flagChannel, "channel", "events:event-1", "default Centrifugo channel namespace:name")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	publisher := NewCentrifugoPublisher(flagCentrifugoURL, flagCentrifugoKey)

	mux := http.NewServeMux()
	mux.HandleFunc("/publish/", handlePublish(publisher))
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })

	log.Printf("Go WS Publisher listening on :%d → Centrifugo: %s (default channel: %s)", flagPort, flagCentrifugoURL, flagChannel)
	if err := http.ListenAndServe(fmt.Sprintf(":%d", flagPort), mux); err != nil {
		log.Printf("server: %v", err)
	}
}

func handlePublish(p *CentrifugoPublisher) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}

		channel := r.URL.Path[len("/publish/"):]
		if channel == "" {
			channel = flagChannel
		} else {
			channel = "events:" + channel
		}

		var data map[string]interface{}
		if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
			data = map[string]interface{}{"ts": time.Now().Unix()}
		}

		start := time.Now()
		if err := p.Publish(r.Context(), channel, data); err != nil {
			log.Printf("publish error: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		log.Printf("published to %s in %v", channel, time.Since(start))
		fmt.Fprintf(w, `{"ok":true,"ch":"%s","latency_ms":%d}`, channel, time.Since(start).Milliseconds())
	}
}
