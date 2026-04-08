package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

var (
	flagTarget   string
	flagAPIKey   string
	flagRate     int
	flagDuration time.Duration
	flagPayload  string
	flagChannel  string
)

func main() {
	fs := flag.NewFlagSet("broadcaster", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "http://localhost:8000", "Centrifugo base URL")
	fs.StringVar(&flagAPIKey, "api-key", "poc-api-key", "Centrifugo API key")
	fs.IntVar(&flagRate, "rate", 1, "broadcasts per second")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "how long to broadcast")
	fs.StringVar(&flagPayload, "payload", `{"seat":"42","status":"held"}`, "JSON payload")
	fs.StringVar(&flagChannel, "channel", "events:event-1", "Centrifugo channel")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	log.Printf("Broadcasting to Centrifugo channel %s at %d/sec for %v", flagChannel, flagRate, flagDuration)

	var totalSent, totalErrors atomic.Int64
	var latencies []time.Duration
	var latMu sync.Mutex

	ticker := time.NewTicker(time.Second / time.Duration(flagRate))
	defer ticker.Stop()

	deadline := time.After(flagDuration)
	broadcastCount := 0

	for {
		select {
		case <-deadline:
			goto done
		case <-ticker.C:
		}

		triggerTime := time.Now()
		go func(seq int) {
			latency, err := broadcast(triggerTime, seq)
			if err != nil {
				totalErrors.Add(1)
				log.Printf("[broadcast %d] error: %v", seq, err)
				return
			}
			totalSent.Add(1)
			latMu.Lock()
			latencies = append(latencies, latency)
			latMu.Unlock()
		}(broadcastCount)
		broadcastCount++
	}

done:
	log.Printf("\n=== Broadcast Summary ===")
	log.Printf("Total sent: %d | Errors: %d", totalSent.Load(), totalErrors.Load())

	latMu.Lock()
	n := len(latencies)
	latMu.Unlock()

	if n > 0 {
		latMu.Lock()
		sorted := make([]time.Duration, n)
		copy(sorted, latencies)
		latMu.Unlock()
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
		log.Printf("p50: %v | p95: %v | p99: %v",
			sorted[n*50/100], sorted[n*95/100], sorted[n*99/100])
	}
}

func broadcast(triggerTime time.Time, seq int) (time.Duration, error) {
	payload := map[string]interface{}{
		"channel": flagChannel,
		"data":    json.RawMessage(flagPayload),
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPost, flagTarget+"/api/publish", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "apikey "+flagAPIKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, err
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return time.Since(triggerTime), fmt.Errorf("centrifugo returned %d", resp.StatusCode)
	}

	return time.Since(triggerTime), nil
}
