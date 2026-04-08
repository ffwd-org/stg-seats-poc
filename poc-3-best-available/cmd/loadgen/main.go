package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"

	"github.com/ffwd-org/stg-seats-poc/pkg/metrics"
)

const pocName = "poc3"

// LatencyCollector is a thread-safe latency sample collector.
type LatencyCollector struct {
	mu   sync.Mutex
	data []float64
}

func (l *LatencyCollector) Append(v float64) {
	l.mu.Lock()
	l.data = append(l.data, v)
	l.mu.Unlock()
}

func (l *LatencyCollector) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.data)
}

func (l *LatencyCollector) Reset() []float64 {
	l.mu.Lock()
	d := l.data
	l.data = nil
	l.mu.Unlock()
	return d
}

func (l *LatencyCollector) Sorted() []float64 {
	d := l.Reset()
	sort.Float64s(d)
	return d
}

var (
	flagMode          string
	flagValkeyAddr    string
	flagWorkers       int
	flagDuration      time.Duration
	flagQuantity      int
	flagSection       string
	flagMetricsPort   int
	flagCooldown      time.Duration
	flagFragmentation string

	totalOps    atomic.Int64
	totalErrors atomic.Int64
	latencies   LatencyCollector
)

func init() {
	metrics.OpsTotal.WithLabelValues(pocName, "ok")
	metrics.OpsTotal.WithLabelValues(pocName, "error")
	metrics.LatencyHist.WithLabelValues(pocName, "best-avail")
	metrics.ActiveWorkers.WithLabelValues(pocName)
}

func main() {
	godotenv.Load()

	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.StringVar(&flagMode, "mode", "best-available", "best-available or random")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagWorkers, "workers", 1000, "concurrent workers")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "test duration")
	fs.IntVar(&flagQuantity, "quantity", 2, "seats per request")
	fs.StringVar(&flagSection, "section", "*", "target section or * for any")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	fs.DurationVar(&flagCooldown, "cooldown", 10*time.Second, "pause between stages")
	fs.StringVar(&flagFragmentation, "fragmentation", "0", "fragmentation label for results file naming")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Printf("Metrics on :%d/metrics", flagMetricsPort)
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	// Load best-available Lua script
	baSrc, err := os.ReadFile("lua/best_available.lua")
	if err != nil {
		log.Fatalf("reading lua script: %v", err)
	}
	baScript := valkey.NewLuaScript(string(baSrc))

	log.Printf("POC 3 load test — mode: %s, workers: %d, quantity: %d, section: %s, fragmentation: %s",
		flagMode, flagWorkers, flagQuantity, flagSection, flagFragmentation)

	runLoadTest(ctx, client, baScript)
}

func runLoadTest(ctx context.Context, client valkey.Client, baScript *valkey.Lua) {
	metrics.ActiveWorkers.WithLabelValues(pocName).Set(float64(flagWorkers))

	ctx, cancel := context.WithTimeout(ctx, flagDuration)
	defer cancel()

	latencies.Reset()
	totalOps.Store(0)
	totalErrors.Store(0)

	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < flagWorkers; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(int64(workerID)))
			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				opStart := time.Now()
				var ok bool
				var err error
				var seatIDs string

				if flagMode == "best-available" {
					ok, seatIDs, err = runBestAvailable(ctx, client, baScript, r)
				} else {
					ok, err = runRandom(ctx, client, r)
				}

				latency := time.Since(opStart).Seconds()
				latencies.Append(latency)

				if err != nil || !ok {
					totalErrors.Add(1)
					metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
					time.Sleep(1 * time.Millisecond)
					continue
				}

				totalOps.Add(1)
				metrics.OpsTotal.WithLabelValues(pocName, "ok").Inc()
				metrics.LatencyHist.WithLabelValues(pocName, "best-avail").Observe(latency)

				// Release seats after successful best-available to maintain
				// stable fragmentation during the test.
				if flagMode == "best-available" && seatIDs != "" {
					releaseSeats(ctx, client, seatIDs)
				}
			}
		}(i)
	}

	// Progress reporter
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				elapsed := time.Since(start).Seconds()
				ops := totalOps.Load()
				log.Printf("  [%.0fs] ops=%d ops/s=%.0f errors=%d",
					elapsed, ops, float64(ops)/elapsed, totalErrors.Load())
			case <-ctx.Done():
				return
			}
		}
	}()

	wg.Wait()

	elapsed := time.Since(start)
	total := totalOps.Load() + totalErrors.Load()
	errRate := 0.0
	if total > 0 {
		errRate = float64(totalErrors.Load()) / float64(total)
	}
	opsPerSec := float64(totalOps.Load()) / elapsed.Seconds()

	vals := latencies.Sorted()
	n := len(vals)
	if n == 0 {
		log.Printf("No operations completed")
		return
	}

	p50 := vals[n*50/100]
	p95 := vals[n*95/100]
	p99 := vals[n*99/100]

	log.Printf("\n=== Results ===")
	log.Printf("ops: %d | ops/s: %.0f | p50: %.4fs | p95: %.4fs | p99: %.4fs | err_rate: %.2f%%",
		totalOps.Load(), opsPerSec, p50, p95, p99, errRate*100)

	writeCSV(vals, opsPerSec, errRate)
	metrics.ActiveWorkers.WithLabelValues(pocName).Set(0)
}

func runBestAvailable(ctx context.Context, client valkey.Client, script *valkey.Lua, r *rand.Rand) (bool, string, error) {
	result, err := script.Exec(ctx, client,
		[]string{"seats:event:1", "venue:event:1:rows"},
		[]string{
			strconv.Itoa(flagQuantity),
			flagSection,
			"50",
			"25",
		},
	).ToString()
	if err != nil {
		return false, "", err
	}
	_ = r // reserved for scoring logic
	if result == "0,no_contiguous_block" || strings.HasPrefix(result, "0,") {
		return false, "", nil
	}
	// Result format: "1,seat:00001,seat:00002,..."
	parts := strings.SplitN(result, ",", 2)
	if len(parts) < 2 {
		return false, "", nil
	}
	return true, parts[1], nil
}

func releaseSeats(ctx context.Context, client valkey.Client, seatIDs string) {
	seats := strings.Split(seatIDs, ",")
	cmds := make(valkey.Commands, 0, len(seats))
	for _, seatID := range seats {
		seatID = strings.TrimSpace(seatID)
		if seatID == "" {
			continue
		}
		cmds = append(cmds, client.B().Hset().Key("seats:event:1").
			FieldValue().FieldValue(seatID, "available").Build())
	}
	if len(cmds) > 0 {
		client.DoMulti(ctx, cmds...)
	}
}

func runRandom(ctx context.Context, client valkey.Client, r *rand.Rand) (bool, error) {
	// Baseline: pick N random seats
	seatIdx := r.Intn(100000)
	seatID := fmt.Sprintf("seat:%05d", seatIdx+1)
	result := client.Do(ctx, client.B().Hget().Key("seats:event:1").Field(seatID).Build())
	status, err := result.ToString()
	if err != nil || status != "available" {
		return false, err
	}
	return true, nil
}

func writeCSV(vals []float64, opsPerSec float64, errRate float64) {
	os.MkdirAll("results", 0755)
	fname := fmt.Sprintf("results/%s-%s-f%s.csv", flagMode, flagSection, flagFragmentation)
	f, err := os.OpenFile(fname, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("csv error: %v", err)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	w.Write([]string{"workers", "ops_per_sec", "p50_ms", "p95_ms", "p99_ms", "error_rate"})
	n := len(vals)
	w.Write([]string{
		strconv.Itoa(flagWorkers),
		fmt.Sprintf("%.2f", opsPerSec),
		fmt.Sprintf("%.4f", vals[n*50/100]*1000),
		fmt.Sprintf("%.4f", vals[n*95/100]*1000),
		fmt.Sprintf("%.4f", vals[n*99/100]*1000),
		fmt.Sprintf("%.6f", errRate),
	})
	w.Flush()
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
