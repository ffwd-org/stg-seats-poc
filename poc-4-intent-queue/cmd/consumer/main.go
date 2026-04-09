package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/queue"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"
)

// latencyStore is a thread-safe reservoir of latency samples with percentile computation.
type latencyStore struct {
	mu      sync.Mutex
	samples []float64 // microseconds
	cap     int
}

func newLatencyStore(cap int) *latencyStore {
	return &latencyStore{
		samples: make([]float64, 0, 1024),
		cap:     cap,
	}
}

func (ls *latencyStore) add(usec float64) {
	ls.mu.Lock()
	if len(ls.samples) < ls.cap {
		ls.samples = append(ls.samples, usec)
	}
	ls.mu.Unlock()
}

func (ls *latencyStore) reset() {
	ls.mu.Lock()
	ls.samples = ls.samples[:0]
	ls.mu.Unlock()
}

// percentiles returns p50, p95, p99 from the current samples.
// It sorts a copy so the underlying slice is not reordered.
func (ls *latencyStore) percentiles() (p50, p95, p99 float64) {
	ls.mu.Lock()
	n := len(ls.samples)
	if n == 0 {
		ls.mu.Unlock()
		return 0, 0, 0
	}
	cp := make([]float64, n)
	copy(cp, ls.samples)
	ls.mu.Unlock()

	sort.Float64s(cp)

	p50 = cp[int(math.Ceil(0.50*float64(n)))-1]
	p95 = cp[int(math.Ceil(0.95*float64(n)))-1]
	p99 = cp[int(math.Ceil(0.99*float64(n)))-1]
	return
}

var (
	flagQueue        string
	flagValkey       string
	flagNATS         string
	flagRedpanda     string
	flagConsumerName string
	flagBatchSize    int
	flagBatchWait    time.Duration
	flagConsumers    int
	flagMetricsPort  int

	consumed, errors   atomic.Int64
	latencySum         atomic.Int64
	latencyCount       atomic.Int64
	latencies          = newLatencyStore(5_000_000)
)

func main() {
	fs := flag.NewFlagSet("consumer", flag.ContinueOnError)
	fs.StringVar(&flagQueue, "queue", "valkey-streams", "valkey-streams|nats|redpanda")
	fs.StringVar(&flagValkey, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.StringVar(&flagNATS, "nats-url", "nats://localhost:4222", "NATS URL")
	fs.StringVar(&flagRedpanda, "redpanda-brokers", "localhost:9092", "Redpanda brokers")
	fs.StringVar(&flagConsumerName, "consumer", "cons1", "Consumer name")
	fs.IntVar(&flagBatchSize, "batch-size", 100, "Max intents per batch")
	fs.DurationVar(&flagBatchWait, "batch-wait", 10*time.Millisecond, "Flush batch after this")
	fs.IntVar(&flagConsumers, "consumers", 1, "Number of consumer goroutines")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2113, "Prometheus metrics port")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("shutting down...")
		cancel()
	}()

	log.Printf("Consumer — queue=%s batch=%d wait=%s consumers=%d",
		flagQueue, flagBatchSize, flagBatchWait, flagConsumers)

	// Shared Valkey client for executing Lua hold scripts
	valkeyClient, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{flagValkey}})
	if err != nil {
		log.Fatalf("valkey client: %v", err)
	}
	defer valkeyClient.Close()

	// Load hold_seat.lua
	holdSrc, err := os.ReadFile("lua/hold_seat.lua")
	if err != nil {
		log.Fatalf("read lua script: %v", err)
	}
	holdSHA := loadScript(ctx, valkeyClient, string(holdSrc))
	log.Printf("Loaded hold_seat.lua SHA=%s", holdSHA)

	// Launch consumer goroutines
	var wg sync.WaitGroup
	for i := 0; i < flagConsumers; i++ {
		wg.Add(1)
		consName := fmt.Sprintf("%s-%d", flagConsumerName, i)
		go func(name string) {
			defer wg.Done()
			runConsumer(ctx, name, valkeyClient, holdSHA)
		}(consName)
	}

	// Periodic stats reporter
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				c := consumed.Load()
				e := errors.Load()
				lc := latencyCount.Load()
				var avgUs int64
				if lc > 0 {
					avgUs = (latencySum.Load() / lc) / 1000 // nanos → micros
				}
				p50, p95, p99 := latencies.percentiles()
				log.Printf("consumed=%d errors=%d avg_latency=%dµs p50=%.0fµs p95=%.0fµs p99=%.0fµs", c, e, avgUs, p50, p95, p99)
			}
		}
	}()

	wg.Wait()
	finalLc := latencyCount.Load()
	var finalAvgUs int64
	if finalLc > 0 {
		finalAvgUs = (latencySum.Load() / finalLc) / 1000
	}
	fp50, fp95, fp99 := latencies.percentiles()
	log.Printf("FINAL consumed=%d errors=%d avg_latency=%dµs p50=%.0fµs p95=%.0fµs p99=%.0fµs", consumed.Load(), errors.Load(), finalAvgUs, fp50, fp95, fp99)
}

func runConsumer(ctx context.Context, name string, valkeyClient valkey.Client, holdSHA string) {
	var cons queue.Consumer
	var err error

	switch flagQueue {
	case "valkey-streams":
		cons, err = queue.NewValkeyStreamsConsumer(ctx, flagValkey, "poc4-group", name)
	case "nats":
		cons, err = queue.NewNATSConsumer(ctx, flagNATS, name)
	case "redpanda":
		cons, err = queue.NewRedpandaConsumer(ctx, strings.Split(flagRedpanda, ","), "poc4-group")
	default:
		log.Fatalf("unsupported queue: %s", flagQueue)
	}
	if err != nil {
		log.Fatalf("consumer %s setup: %v", name, err)
	}
	defer cons.Close()

	for {
		if ctx.Err() != nil {
			return
		}

		intents, fetchErr := cons.FetchBatch(ctx, flagBatchSize)
		if fetchErr != nil {
			if ctx.Err() != nil {
				return
			}
			log.Printf("consumer %s fetch: %v", name, fetchErr)
			time.Sleep(flagBatchWait)
			continue
		}
		if len(intents) == 0 {
			time.Sleep(flagBatchWait)
			continue
		}

		executeBatchPipelined(ctx, valkeyClient, holdSHA, intents)
	}
}

// executeBatchPipelined uses DoMulti to pipeline all EVALSHA calls in one round trip.
func executeBatchPipelined(ctx context.Context, client valkey.Client, holdSHA string, batch []*intent.HoldIntent) {
	now := time.Now().UnixNano()

	cmds := make(valkey.Commands, 0, len(batch))
	for _, h := range batch {
		seatKey := fmt.Sprintf("seats:event:%d", h.EventID)
		seatID := fmt.Sprintf("seat:%05d", h.SeatID)
		userID := fmt.Sprintf("%d", h.UserID)
		ttl := fmt.Sprintf("%d", h.HoldTTL)
		nowStr := fmt.Sprintf("%d", time.Now().Unix())

		cmd := client.B().Evalsha().Sha1(holdSHA).Numkeys(1).Key(seatKey).Arg(seatID, userID, ttl, nowStr).Build()
		cmds = append(cmds, cmd)

		// Record e2e latency
		if h.Timestamp > 0 {
			e2eNanos := now - int64(h.Timestamp)
			if e2eNanos > 0 {
				latencySum.Add(e2eNanos)
				latencyCount.Add(1)
				latencies.add(float64(e2eNanos) / 1000.0)
			}
		}
	}

	results := client.DoMulti(ctx, cmds...)
	for _, res := range results {
		if res.Error() != nil {
			errors.Add(1)
		} else {
			consumed.Add(1)
		}
	}
}

// loadScript does SCRIPT LOAD and returns the SHA.
func loadScript(ctx context.Context, client valkey.Client, script string) string {
	cmd := client.B().ScriptLoad().Script(script).Build()
	sha, err := client.Do(ctx, cmd).ToString()
	if err != nil {
		log.Fatalf("SCRIPT LOAD: %v", err)
	}
	return sha
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
