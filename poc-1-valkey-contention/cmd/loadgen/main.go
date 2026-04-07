package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"math/rand"

	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"

	"github.com/ffwd-org/stg-seats-poc/pkg/metrics"
)

const pocName = "poc1"

// latencyCollector is a concurrent-safe latency sample store with a cap.
const maxLatencySamples = 500_000

type latencyCollector struct {
	mu   sync.Mutex
	vals []float64
}

func newLatencyCollector() *latencyCollector {
	return &latencyCollector{vals: make([]float64, 0, 65536)}
}

func (l *latencyCollector) reset() {
	l.mu.Lock()
	l.vals = l.vals[:0]
	l.mu.Unlock()
}

func (l *latencyCollector) add(v float64) {
	l.mu.Lock()
	if len(l.vals) < maxLatencySamples {
		l.vals = append(l.vals, v)
	}
	l.mu.Unlock()
}

func (l *latencyCollector) percentiles() (p50, p95, p99 float64) {
	l.mu.Lock()
	cp := make([]float64, len(l.vals))
	copy(cp, l.vals)
	l.mu.Unlock()

	if len(cp) == 0 {
		return 0, 0, 0
	}
	sort.Float64s(cp)
	n := len(cp)
	return cp[n*50/100], cp[n*95/100], cp[n*99/100]
}

var (
	flagMode        string
	flagValkeyAddr  string
	flagSeats       int
	flagRamp        string
	flagMetricsPort int
	flagStageDur    time.Duration
	flagCooldown    time.Duration

	totalOps    atomic.Int64
	totalErrors atomic.Int64
	latencies   = newLatencyCollector()
)

func init() {
	metrics.OpsTotal.WithLabelValues(pocName, "ok")
	metrics.OpsTotal.WithLabelValues(pocName, "error")
	metrics.LatencyHist.WithLabelValues(pocName, "hold")
	metrics.ActiveWorkers.WithLabelValues(pocName)
}

type stageResult struct {
	Workers   int
	Ops       int64
	OpsPerSec float64
	P50       float64
	P95       float64
	P99       float64
	ErrorRate float64
}

func main() {
	godotenv.Load()

	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.StringVar(&flagMode, "mode", "", "hset or bitfield (required)")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagSeats, "seats", 100000, "total seat count")
	fs.StringVar(&flagRamp, "ramp", "100,1000,5000,10000,25000,50000,100000", "comma-separated worker counts")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	fs.DurationVar(&flagStageDur, "stage-duration", 60*time.Second, "how long each ramp stage runs")
	fs.DurationVar(&flagCooldown, "cooldown", 10*time.Second, "pause between stages")
	if err := fs.Parse(os.Args[1:]); err != nil {
		slog.Error("flag parse failed", "err", err)
		os.Exit(1)
	}

	if flagMode == "" {
		slog.Error("--mode is required (hset or bitfield)")
		os.Exit(1)
	}

	var workerCounts []int
	for _, s := range strings.Split(flagRamp, ",") {
		n, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil {
			slog.Error("invalid worker count in --ramp", "value", s)
			os.Exit(1)
		}
		workerCounts = append(workerCounts, n)
	}

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		addr := fmt.Sprintf(":%d", flagMetricsPort)
		slog.Info("metrics server listening", "addr", addr)
		if err := http.ListenAndServe(addr, nil); err != nil {
			slog.Error("metrics server", "err", err)
		}
	}()

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		slog.Error("valkey client", "err", err)
		os.Exit(1)
	}
	defer client.Close()

	scripts := loadScripts()

	slog.Info("starting POC 1 load test", "mode", flagMode, "seats", flagSeats, "stages", workerCounts)

	results := make([]stageResult, 0, len(workerCounts))
	for i, workers := range workerCounts {
		slog.Info("stage start", "stage", i+1, "of", len(workerCounts), "workers", workers)
		res := runStage(ctx, client, workers, scripts)
		results = append(results, res)
		printStageResult(res)
		writeCSV(results, flagMode)

		if i < len(workerCounts)-1 && flagCooldown > 0 {
			slog.Info("cooldown", "duration", flagCooldown)
			time.Sleep(flagCooldown)
		}
	}

	slog.Info("all stages complete")
	writeCSV(results, flagMode)
}

func runStage(ctx context.Context, client valkey.Client, nWorkers int, scripts *loadedScripts) stageResult {
	metrics.ActiveWorkers.WithLabelValues(pocName).Set(float64(nWorkers))

	stageCtx, cancel := context.WithTimeout(ctx, flagStageDur)
	defer cancel()

	latencies.reset()
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
				slog.Info("progress", "elapsed_s", fmt.Sprintf("%.0f", elapsed),
					"ops", ops, "ops_per_s", fmt.Sprintf("%.0f", float64(ops)/elapsed),
					"errors", totalErrors.Load())
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
			runWorker(stageCtx, client, workerID, scripts)
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
	p50, p95, p99 := latencies.percentiles()

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

func runWorker(ctx context.Context, client valkey.Client, workerID int, scripts *loadedScripts) {
	r := rand.New(rand.NewSource(int64(workerID)))
	key := keyForMode(flagMode)
	workerToken := fmt.Sprintf("worker-%d", workerID)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		seatIdx := r.Intn(flagSeats)
		seatID := fmt.Sprintf("seat:%05d", seatIdx+1)

		opStart := time.Now()
		var resp valkey.ValkeyResult

		if flagMode == "hset" {
			resp = scripts.holdHSET.Exec(ctx, client,
				[]string{key},
				[]string{seatID, workerToken, "60", strconv.FormatInt(time.Now().Unix(), 10)},
			)
		} else {
			resp = scripts.holdBitfield.Exec(ctx, client,
				[]string{key, key + ":holders"},
				[]string{strconv.Itoa(seatIdx), workerToken},
			)
		}

		latency := time.Since(opStart).Seconds()

		if err := resp.Error(); err != nil {
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
			time.Sleep(time.Millisecond)
			continue
		}

		arr, err := resp.ToArray()
		if err != nil || len(arr) == 0 {
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
			time.Sleep(time.Millisecond)
			continue
		}

		code, _ := arr[0].ToInt64()
		if code == 0 {
			// seat_unavailable — expected under contention, not a fatal error
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
			time.Sleep(time.Millisecond)
			continue
		}

		latencies.add(latency)
		totalOps.Add(1)
		metrics.OpsTotal.WithLabelValues(pocName, "ok").Inc()
		metrics.LatencyHist.WithLabelValues(pocName, "hold").Observe(latency)
	}
}

type loadedScripts struct {
	holdHSET     *valkey.Lua
	holdBitfield *valkey.Lua
}

func loadScripts() *loadedScripts {
	hsetSrc, err := os.ReadFile("lua/hold_hset.lua")
	if err != nil {
		slog.Error("failed to read hold_hset.lua", "err", err)
		os.Exit(1)
	}
	bitfieldSrc, err := os.ReadFile("lua/hold_bitfield.lua")
	if err != nil {
		slog.Error("failed to read hold_bitfield.lua", "err", err)
		os.Exit(1)
	}
	return &loadedScripts{
		holdHSET:     valkey.NewLuaScript(string(hsetSrc)),
		holdBitfield: valkey.NewLuaScript(string(bitfieldSrc)),
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

func printStageResult(r stageResult) {
	slog.Info("stage result",
		"workers", r.Workers,
		"ops", r.Ops,
		"ops_per_sec", fmt.Sprintf("%.0f", r.OpsPerSec),
		"p50_ms", fmt.Sprintf("%.3f", r.P50*1000),
		"p95_ms", fmt.Sprintf("%.3f", r.P95*1000),
		"p99_ms", fmt.Sprintf("%.3f", r.P99*1000),
		"error_rate_pct", fmt.Sprintf("%.2f", r.ErrorRate*100),
	)
}

func writeCSV(results []stageResult, mode string) {
	os.MkdirAll("results", 0755)
	fname := fmt.Sprintf("results/%s-run.csv", mode)
	f, err := os.OpenFile(fname, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		slog.Error("csv write error", "err", err)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	_ = w.Write([]string{"workers", "ops", "ops_per_sec", "p50_s", "p95_s", "p99_s", "error_rate"})
	for _, r := range results {
		_ = w.Write([]string{
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

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
