package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/queue"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	flagQueue       string
	flagRate        int
	flagValkey      string
	flagNATS        string
	flagRedpanda    string
	flagMetricsPort int
	flagDuration    time.Duration
	flagEventID     uint64

	produced, errors atomic.Int64
)

func main() {
	fs := flag.NewFlagSet("producer", flag.ContinueOnError)
	fs.StringVar(&flagQueue, "queue", "direct", "direct|valkey-streams|nats|redpanda")
	fs.StringVar(&flagValkey, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.StringVar(&flagNATS, "nats-url", "nats://localhost:4222", "NATS URL")
	fs.StringVar(&flagRedpanda, "redpanda-brokers", "localhost:9092", "Redpanda brokers")
	fs.IntVar(&flagRate, "rate", 1000, "intents per second")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "test duration")
	fs.Uint64Var(&flagEventID, "event-id", 1, "event ID")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	log.Printf("Producer — queue=%s rate=%d/s duration=%s", flagQueue, flagRate, flagDuration)

	var q queue.Producer
	var err error

	switch flagQueue {
	case "valkey-streams":
		q, err = queue.NewValkeyStreamsProducer(ctx, flagValkey)
	case "nats":
		q, err = queue.NewNATSProducer(ctx, flagNATS)
	case "redpanda":
		q, err = queue.NewRedpandaProducer(ctx, strings.Split(flagRedpanda, ","))
	case "direct":
		log.Fatal("direct mode — use cmd/direct instead")
	default:
		log.Fatalf("unknown queue: %s", flagQueue)
	}
	if err != nil {
		log.Fatalf("producer setup: %v", err)
	}
	defer q.Close()

	ticker := time.NewTicker(time.Second / time.Duration(flagRate))
	defer ticker.Stop()

	i := uint64(0)
	for {
		select {
		case <-ctx.Done():
			goto done
		case <-ticker.C:
			i++
			go func(seq uint64) {
				h := makeIntent(flagEventID, seq)
				if sendErr := q.Send(ctx, h); sendErr != nil {
					errors.Add(1)
					return
				}
				produced.Add(1)
			}(i)
		}
	}

done:
	log.Printf("produced=%d errors=%d", produced.Load(), errors.Load())
}

func makeIntent(eventID, seq uint64) *intent.HoldIntent {
	return &intent.HoldIntent{
		EventID:   eventID,
		SeatID:    uint32(seq % 100_000),
		UserID:    rand.Uint64(),
		HoldTTL:   60,
		Timestamp: uint64(time.Now().UnixNano()),
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
