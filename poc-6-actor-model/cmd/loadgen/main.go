//go:build ignore

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
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const pocName = "poc6"

var (
	flagTarget      string
	flagWorkers     int
	flagDuration    time.Duration
	flagQuantity    int
	flagMetricsPort int

	totalOps    atomic.Int64
	totalErrors atomic.Int64
	latencies  atomic.Uint64Slice
	latMu      sync.Mutex
)

func main() {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "http://localhost:4000", "Elixir HTTP endpoint")
	fs.IntVar(&flagWorkers, "workers", 1000, "concurrent workers")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "test duration")
	fs.IntVar(&flagQuantity, "quantity", 2, "seats per request")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	log.Printf("POC 6 loadgen — target: %s, workers: %d, duration: %s",
		flagTarget, flagWorkers, flagDuration)

	runTest(ctx)
}

func runTest(ctx context.Context) {
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
				err := holdSeat(ctx, r)

				latency := time.Since(opStart).Seconds()
				latMu.Lock()
				latencies.Append(uint64(latency * 1e6))
				latMu.Unlock()

				if err != nil {
					totalErrors.Add(1)
					time.Sleep(1 * time.Millisecond)
				} else {
					totalOps.Add(1)
				}
			}
		}(i)
	}

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	go func() {
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

	latMu.Lock()
	n := latencies.Len()
	vals := make([]float64, n)
	for i := 0; i < n; i++ {
		vals[i] = float64(latencies.At(i)) / 1e6
	}
	latMu.Unlock()
	sort.Float64s(vals)

	p50 := vals[n*50/100]
	p95 := vals[n*95/100]
	p99 := vals[n*99/100]

	log.Printf("\n=== Results ===")
	log.Printf("ops: %d | ops/s: %.0f | p50: %.4fs | p95: %.4fs | p99: %.4fs | err_rate: %.2f%%",
		totalOps.Load(), opsPerSec, p50, p95, p99, errRate*100)

	writeCSV(vals, opsPerSec, errRate)
}

func holdSeat(ctx context.Context, r *rand.Rand) error {
	sectionID := r.Intn(20)           // 0-19
	seatIndex := r.Intn(5000)         // 0-4999 per section
	quantity := flagQuantity

	reqBody := fmt.Sprintf(
		`{"action":"hold","section_id":%d,"quantity":%d,"hold_token":"worker-%d","ttl_seconds":60}`,
		sectionID, quantity, r.Int())

	req, err := http.NewRequestWithContext(ctx, "POST",
		fmt.Sprintf("%s/seat/hold", flagTarget),
		nil)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func writeCSV(vals []float64, opsPerSec float64, errRate float64) {
	os.MkdirAll("results", 0755)
	f, _ := os.OpenFile("results/elixir-actor.csv",
		os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	defer f.Close()
	w := csv.NewWriter(f)
	w.Write([]string{"workers", "ops_per_sec", "p50_ms", "p95_ms", "p99_ms", "error_rate"})
	n := len(vals)
	w.Write([]string{
		fmt.Sprintf("%d", flagWorkers),
		fmt.Sprintf("%.2f", opsPerSec),
		fmt.Sprintf("%.4f", vals[n*50/100]),
		fmt.Sprintf("%.4f", vals[n*95/100]),
		fmt.Sprintf("%.4f", vals[n*99/100]),
		fmt.Sprintf("%.6f", errRate),
	})
	w.Flush()
}
