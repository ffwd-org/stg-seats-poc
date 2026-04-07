//go:build ignore

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
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
	flagEventID  string
)

func main() {
	fs := flag.NewFlagSet("broadcaster", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "http://localhost:8000/api", "Centrifugo API URL")
	fs.StringVar(&flagAPIKey, "api-key", "", "Centrifugo API key")
	fs.IntVar(&flagRate, "rate", 1, "broadcasts per second")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "how long to broadcast")
	fs.StringVar(&flagPayload, "payload", `{"seat":"42","status":"held"}`, "JSON payload")
	fs.StringVar(&flagEventID, "event", "1", "event ID for channel")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	log.Printf("Broadcasting to Centrifugo channel stg-seats:%s at %d/sec", flagEventID, flagRate)

	var totalSent, totalErrors atomic.Int64
	var latencies []time.Duration
	var latMu sync.Mutex

	ticker := time.NewTicker(time.Second / time.Duration(flagRate))
	defer ticker.Stop()

	endpoint := time.After(flagDuration)
	broadcastCount := 0

	for {
		select {
		case <-ctx.Done():
			goto done
		case <-ticker.C:
		case <-endpoint:
			goto done
		}

		triggerTime := time.Now()
		go func(seq int) {
			latency, err := broadcast(triggerTime, seq)
			if err != nil {
				totalErrors.Add(1)
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
		"method": "broadcast",
		"params": map[string]interface{}{
			"channel": "stg-seats:" + flagEventID,
			"data":    json.RawMessage(flagPayload),
		},
	}
	body, _ := json.Marshal(payload)
	req, err := http.NewRequest(http.MethodPost, flagTarget+"/rpc", bytes.NewReader(body))
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

	return time.Since(triggerTime), nil
}
