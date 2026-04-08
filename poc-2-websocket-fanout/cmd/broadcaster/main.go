package main

import (
	"bytes"
	"context"
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
	flagRate     int
	flagDuration time.Duration
	flagPayload  string
	flagEventID  string
)

func main() {
	fs := flag.NewFlagSet("broadcaster", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "", "HTTP broadcast endpoint (required)")
	fs.IntVar(&flagRate, "rate", 1, "broadcasts per second")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "how long to broadcast")
	fs.StringVar(&flagPayload, "payload", `{"seat":"42","status":"held"}`, "JSON payload")
	fs.StringVar(&flagEventID, "event", "1", "event ID")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	if flagTarget == "" {
		flagTarget = fmt.Sprintf("http://localhost:8080/broadcast/%s", flagEventID)
	}

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	log.Printf("Broadcasting to %s at %d/sec for %s", flagTarget, flagRate, flagDuration)
	log.Printf("Payload: %s", flagPayload)

	var totalSent, totalErrors atomic.Int64
	var latencies []time.Duration
	var latMu sync.Mutex

	interval := time.Second / time.Duration(flagRate)
	ticker := time.NewTicker(interval)
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
			req, _ := http.NewRequest(http.MethodPost, flagTarget, bytes.NewBufferString(flagPayload))
			req.Header.Set("Content-Type", "application/json")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				totalErrors.Add(1)
				log.Printf("[broadcast %d] error: %v", seq, err)
				return
			}
			io.ReadAll(resp.Body)
			resp.Body.Close()

			latency := time.Since(triggerTime)
			latMu.Lock()
			latencies = append(latencies, latency)
			latMu.Unlock()

			totalSent.Add(1)
			if seq%10 == 0 {
				log.Printf("[broadcast %d] sent, latency=%v", seq, latency)
			}
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
		log.Printf("p50 latency: %v", sorted[n*50/100])
		log.Printf("p95 latency: %v", sorted[n*95/100])
		log.Printf("p99 latency: %v", sorted[n*99/100])
	}
}
