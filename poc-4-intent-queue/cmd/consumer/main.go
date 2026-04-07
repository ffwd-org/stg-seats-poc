//go:build ignore

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/queue"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"
)

var (
	flagQueue        string
	flagValkey       string
	flagNATS         string
	flagRedpanda     string
	flagConsumerName string
	flagBatchSize    int
	flagBatchTimeout time.Duration
	flagMetricsPort  int

	consumed, errors atomic.Int64
)

func main() {
	fs := flag.NewFlagSet("consumer", flag.ContinueOnError)
	fs.StringVar(&flagQueue, "queue", "valkey-streams", "valkey-streams|nats|redpanda")
	fs.StringVar(&flagValkey, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.StringVar(&flagNATS, "nats-url", "nats://localhost:4222", "NATS URL")
	fs.StringVar(&flagRedpanda, "redpanda-brokers", "localhost:9092", "Redpanda brokers")
	fs.StringVar(&flagConsumerName, "consumer", "cons1", "Consumer group name")
	fs.IntVar(&flagBatchSize, "batch-size", 50, "Max intents per batch")
	fs.DurationVar(&flagBatchTimeout, "batch-timeout", 100*time.Millisecond, "Flush batch after this")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	log.Printf("Consumer — queue=%s batch=%d timeout=%s", flagQueue, flagBatchSize, flagBatchTimeout)

	valkeyClient, err := valkey.NewClient(valkey.Option{InitAddress: []string{flagValkey}})
	if err != nil {
		log.Fatalf("valkey client: %v", err)
	}
	defer valkeyClient.Close()

	holdSrc, _ := os.ReadFile("lua/hold_seat.lua")
	holdScript := valkey.NewScript(string(holdSrc))

	batch := make([]*intent.HoldIntent, 0, flagBatchSize)
	batchTimer := time.NewTimer(flagBatchTimeout)

	for {
		select {
		case <-ctx.Done():
			if len(batch) > 0 {
				executeBatch(ctx, valkeyClient, holdScript, batch)
			}
			return
		case <-batchTimer.C:
			if len(batch) > 0 {
				executeBatch(ctx, valkeyClient, holdScript, batch)
				batch = batch[:0]
			}
			batchTimer.Reset(flagBatchTimeout)
		default:
			h, err := readOne(ctx)
			if err != nil {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			batch = append(batch, h)
			if len(batch) >= flagBatchSize {
				executeBatch(ctx, valkeyClient, holdScript, batch)
				batch = batch[:0]
				batchTimer.Reset(flagBatchTimeout)
			}
		}
	}
}

func readOne(ctx context.Context) (*intent.HoldIntent, error) {
	switch flagQueue {
	case "valkey-streams":
		c, err := queue.NewValkeyStreamsConsumer(ctx, flagValkey, "seat:holds:stream", "poc4-group", flagConsumerName)
		if err != nil {
			return nil, err
		}
		defer c.Close()
		records, err := c.ReadGroup(ctx, "seat:holds:stream", flagConsumerName, 1)
		if err != nil || len(records) < 2 {
			return nil, fmt.Errorf("no message")
		}
		return intent.Decode([]byte(records[1]))
	default:
		return nil, fmt.Errorf("unsupported queue: %s", flagQueue)
	}
}

func executeBatch(ctx context.Context, client valkey.Client, script *valkey.Script, batch []*intent.HoldIntent) {
	for _, h := range batch {
		seatKey := fmt.Sprintf("seats:event:%d", h.EventID)
		seatID := fmt.Sprintf("seat:%05d", h.SeatID)
		_, err := script.Exec(ctx, client,
			[]string{seatKey},
			[]interface{}{seatID, string(h.HoldToken[:]), h.TTLSeconds, h.NowUnix}).ToString()
		if err != nil {
			errors.Add(1)
			continue
		}
		consumed.Add(1)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
