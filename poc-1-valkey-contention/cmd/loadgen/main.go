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
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/adaptor"
	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"

	"github.com/ffwd-org/stg-seats-poc/pkg/metrics"
)

const pocName = "poc1"

var (
	flagWorkers      int
	flagDuration     time.Duration
	flagMode         string
	flagValkeyAddr   string
	flagSeats        int
	flagRamp         string
	flagMetricsPort  int
	flagStageDur     time.Duration
	flagCooldown     time.Duration

	totalOps    atomic.Int64
	totalErrors atomic.Int64
	latencies   atomic.Uint64Slice // guarded by sort mutex
	sortMu      sync.Mutex
)

func init() {
	// Register Prometheus metrics
	metrics.OpsTotal.WithLabelValues(pocName, "ok")
	metrics.OpsTotal.WithLabelValues(pocName, "error")
	metrics.LatencyHist.WithLabelValues(pocName, "hold")
	metrics.ActiveWorkers.WithLabelValues(pocName)
}

type stageResult struct {
	Workers    int
	Ops        int64
	OpsPerSec  float64
	P50        float64
	P95        float64
	P99        float64
	ErrorRate  float64
}

func main() {
	godotenv.Load()

	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.IntVar(&flagWorkers, "workers", 1000, "concurrent goroutines per stage")
	fs.DurationVar(&flagDuration, "duration", 60*time.Second, "test duration per stage")
	fs.StringVar(&flagMode, "mode", "", "hset or bitfield (required)")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagSeats, "seats", 100000, "total seat count")
	fs.StringVar(&flagRamp, "ramp", "100,1000,5000,10000,25000,50000,100000", "comma-separated worker counts")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	fs.DurationVar(&flagStageDur, "stage-duration", 60*time.Second, "how long each ramp stage runs")
	fs.DurationVar(&flagCooldown, "cooldown", 10*time.Second, "pause between stages")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	if flagMode == "" {
		log.Fatal("--mode is required (hset or bitfield)")
	}

	// Parse ramp stages
	var workerCounts []int
	for _, s := range splitComma(flagRamp) {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			log.Fatalf("invalid worker count in --ramp: %s", s)
		}
		workerCounts = append(workerCounts, n)
	}

	// Start Prometheus metrics server
	go func() {
		http.Handle("/metrics", promhttp.Handler())
		addr := fmt.Sprintf(":%d", flagMetricsPort)
		log.Printf("Metrics server listening on %s", addr)
		if err := http.ListenAndServe(addr, nil); err != nil {
			log.Printf("metrics server: %v", err)
		}
	}()

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.Option{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		log.Fatalf("valkey client: %v", err)
	}
	defer client.Close()

	// Load Lua scripts
	scripts := loadScripts(client, flagMode)

	log.Printf("Starting POC 1 load test — mode: %s, seats: %d", flagMode, flagSeats)
	log.Printf("Stages: %v", workerCounts)

	results := make([]stageResult, 0, len(workerCounts))
	for i, workers := range workerCounts {
		fmt.Printf("\n=== Stage %d/%d: %d workers ===\n", i+1, len(workerCounts), workers)
		res := runStage(ctx, client, workers, scripts, flagMode)
		results = append(results, res)
		printStageResult(res)

		// Write CSV after each stage
		writeCSV(results, flagMode)

		if i < len(workerCounts)-1 && flagCooldown > 0 {
			log.Printf("Cooldown for %s...", flagCooldown)
			time.Sleep(flagCooldown)
		}
	}

	fmt.Println("\n=== ALL STAGES COMPLETE ===")
	writeCSV(results, flagMode)
}

func runStage(ctx context.Context, client valkey.Client, nWorkers int, scripts *loadedScripts, mode string) stageResult {
	metrics.ActiveWorkers.WithLabelValues(pocName).Set(float64(nWorkers))

	ctx, cancel := context.WithTimeout(ctx, flagStageDur)
	defer cancel()

	latencies.Reset()
	totalOps.Store(0)
	totalErrors.Store(0)

	start := time.Now()
	reportDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				elapsed := time.Since(start).Seconds()
				ops := totalOps.Load()
				fmt.Printf("  [%.0fs] ops=%d ops/s=%.0f errors=%d\n",
					elapsed, ops, float64(ops)/elapsed, totalErrors.Load())
			case <-reportDone:
				return
			}
		}
	}()

	var wg sync.WaitGroup
	for i := 0; i < nWorkers; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			runWorker(ctx, client, workerID, scripts, mode)
		}(i)
	}
	wg.Wait()
	close(reportDone)

	elapsed := time.Since(start)
	total := totalOps.Load() + totalErrors.Load()
	errRate := 0.0
	if total > 0 {
		errRate = float64(totalErrors.Load()) / float64(total)
	}

	opsPerSec := float64(totalOps.Load()) / elapsed.Seconds()
	p50, p95, p99 := computePercentiles()

	metrics.ActiveWorkers.WithLabelValues(pocName).Set(0)

	return stageResult{
		Workers:   nWorkers,
		Ops:       totalOps.Load(),
		OpsPerSec: opsPerSec,
		P50:       p50,
		P95:       p95,
		P99:       p99,
		ErrorRate: errRate,
	}
}

func runWorker(ctx context.Context, client valkey.Client, workerID int, scripts *loadedScripts, mode string) {
	r := rand.New(rand.NewSource(int64(workerID)))
	key := keyForMode(mode)
	holdersKey := "seats:event:1:holders"

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		seatIdx := r.Intn(flagSeats)
		seatID := fmt.Sprintf("seat:%05d", seatIdx+1)

		opStart := time.Now()
		var result string
		var err error

		if mode == "hset" {
			result, err = scripts.holdHSET.Exec(ctx, client, []string{key}, []interface{}{seatID, fmt.Sprintf("worker-%d", workerID), 60, time.Now().Unix()}).ToString()
		} else {
			result, err = scripts.holdBitfield.Exec(ctx, client, []string{key, holdersKey}, []interface{}{seatIdx, fmt.Sprintf("worker-%d", workerID)}).ToString()
		}

		latency := time.Since(opStart).Seconds()
		latencies.Append(uint64(latency * 1e6)) // microseconds for precision

		if err != nil || result == "seat_unavailable" {
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
			// Brief backoff on contention
			time.Sleep(1 * time.Millisecond)
			continue
		}

		totalOps.Add(1)
		metrics.OpsTotal.WithLabelValues(pocName, "ok").Inc()
		metrics.LatencyHist.WithLabelValues(pocName, "hold").Observe(latency)
	}
}

type loadedScripts struct {
	holdHSET    *valkey.Script
	holdBitfield *valkey.Script
}

func loadScripts(client valkey.Client, mode string) *loadedScripts {
	hsetSrc, _ := os.ReadFile("lua/hold_hset.lua")
	bitfieldSrc, _ := os.ReadFile("lua/hold_bitfield.lua")
	return &loadedScripts{
		holdHSET:     valkey.NewScript(string(hsetSrc)),
		holdBitfield: valkey.NewScript(string(bitfieldSrc)),
	}
}

func keyForMode(mode string) string {
	switch mode {
	case "hset":
		return "seats:event:1"
	case "bitfield":
		return "seats:event:1:bits"
	default:
		return "seats:event:1"
	}
}

func computePercentiles() (p50, p95, p99 float64) {
	sortMu.Lock()
	vals := make([]float64, latencies.Len())
	for i := range vals {
		vals[i] = float64(latencies.At(i)) / 1e6 // back to seconds
	}
	sortMu.Unlock()

	if len(vals) == 0 {
		return 0, 0, 0
	}
	sort.Float64s(vals)
	n := len(vals)
	return vals[n*50/100], vals[n*95/100], vals[n*99/100]
}

func printStageResult(r stageResult) {
	fmt.Printf("  Result: ops=%d ops/s=%.0f p50=%.4fs p95=%.4fs p99=%.4fs error_rate=%.2f%%\n",
		r.Ops, r.OpsPerSec, r.P50, r.P95, r.P99, r.ErrorRate*100)
}

func writeCSV(results []stageResult, mode string) {
	os.MkdirAll("results", 0755)
	fname := fmt.Sprintf("results/%s-run.csv", mode)
	f, err := os.OpenFile(fname, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("csv write error: %v", err)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	w.Write([]string{"workers", "ops", "ops_per_sec", "p50_s", "p95_s", "p99_s", "error_rate"})
	for _, r := range results {
		w.Write([]string{
			strconv.Itoa(r.Workers),
			strconv.FormatInt(r.Ops, 10),
			fmt.Sprintf("%.2f", r.OpsPerSec),
			fmt.Sprintf("%.6f", r.P50),
			fmt.Sprintf("%.6f", r.P95),
			fmt.Sprintf("%.6f", r.P99),
			fmt.Sprintf("%.6f", r.ErrorRate),
		})
	}
	w.Flush()
}

func splitComma(s string) []string {
	var parts []string
	quote := false
	var buf []byte
	for i := 0; i < len(s); i++ {
		if s[i] == '"' {
			quote = !quote
		} else if s[i] == ',' && !quote {
			parts = append(parts, string(buf))
			buf = nil
		} else {
			buf = append(buf, s[i])
		}
	}
	if len(buf) > 0 {
		parts = append(parts, string(buf))
	}
	return parts
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
