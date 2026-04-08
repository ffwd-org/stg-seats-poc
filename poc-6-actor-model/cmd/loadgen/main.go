package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

const pocName = "poc6"

// LatencyCollector is a thread-safe collector for latency samples.
type LatencyCollector struct {
	mu   sync.Mutex
	data []float64
}

func (l *LatencyCollector) Append(v float64) {
	l.mu.Lock()
	l.data = append(l.data, v)
	l.mu.Unlock()
}

func (l *LatencyCollector) Reset() []float64 {
	l.mu.Lock()
	d := l.data
	l.data = nil
	l.mu.Unlock()
	return d
}

func (l *LatencyCollector) Snapshot() []float64 {
	l.mu.Lock()
	d := make([]float64, len(l.data))
	copy(d, l.data)
	l.mu.Unlock()
	return d
}

var (
	flagTarget      string
	flagWorkers     int
	flagDuration    time.Duration
	flagQuantity    int
	flagSection     int
	flagMetricsPort int

	totalOps    atomic.Int64
	totalErrors atomic.Int64
	latencies   LatencyCollector
)

func main() {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.StringVar(&flagTarget, "target", "http://localhost:4000", "Elixir HTTP endpoint")
	fs.IntVar(&flagWorkers, "workers", 1000, "concurrent workers")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "test duration")
	fs.IntVar(&flagQuantity, "quantity", 2, "seats per request")
	fs.IntVar(&flagSection, "section", -1, "target section (-1 = random)")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), flagDuration)
	defer cancel()

	log.Printf("POC 6 loadgen -- target: %s, workers: %d, duration: %s, section: %d",
		flagTarget, flagWorkers, flagDuration, flagSection)

	// Seed the venue first
	seedVenue()

	runTest(ctx)
}

func seedVenue() {
	body := `{"seats":100000,"sections":20,"fragmentation":0}`
	resp, err := http.Post(flagTarget+"/seed", "application/json", bytes.NewBufferString(body))
	if err != nil {
		log.Printf("WARNING: seed failed: %v", err)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	log.Printf("Venue seeded (100K seats, 20 sections)")
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
			client := &http.Client{Timeout: 10 * time.Second}

			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				opStart := time.Now()
				err := holdSeat(ctx, r, client)

				latency := time.Since(opStart).Seconds()
				latencies.Append(latency)

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

	vals := latencies.Snapshot()
	sort.Float64s(vals)
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
}

func holdSeat(ctx context.Context, r *rand.Rand, client *http.Client) error {
	sectionID := flagSection
	if sectionID < 0 {
		sectionID = r.Intn(20)
	}
	quantity := flagQuantity

	body := fmt.Sprintf(
		`{"section_id":%d,"quantity":%d,"hold_token":"worker-%d","ttl_seconds":60}`,
		sectionID, quantity, r.Int())

	req, err := http.NewRequestWithContext(ctx, "POST",
		flagTarget+"/hold",
		bytes.NewBufferString(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}

func writeCSV(vals []float64, opsPerSec float64, errRate float64) {
	os.MkdirAll("results", 0755)
	f, err := os.OpenFile("results/elixir-actor.csv",
		os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("WARNING: could not write CSV: %v", err)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	n := len(vals)
	w.Write([]string{"workers", "ops_per_sec", "p50_s", "p95_s", "p99_s", "error_rate"})
	w.Write([]string{
		fmt.Sprintf("%d", flagWorkers),
		fmt.Sprintf("%.2f", opsPerSec),
		fmt.Sprintf("%.6f", vals[n*50/100]),
		fmt.Sprintf("%.6f", vals[n*95/100]),
		fmt.Sprintf("%.6f", vals[n*99/100]),
		fmt.Sprintf("%.6f", errRate),
	})
	w.Flush()
	log.Printf("Results written to results/elixir-actor.csv")
}
