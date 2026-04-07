package main

import (
	"context"
	"encoding/csv"
	"flag"
	"fmt"
	"log/slog"
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
	valkey "github.com/valkey-io/valkey-go"

	"github.com/ffwd-org/stg-seats-poc/poc-1-valkey-contention/pkg/metrics"
)

const pocName = "poc1"

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
	latColl     latencyCollector
)

func init() {
	for _, m := range []string{"hset", "bitfield"} {
		metrics.OpsTotal.WithLabelValues(pocName, m, "ok")
		metrics.OpsTotal.WithLabelValues(pocName, m, "error")
		metrics.LatencyHist.WithLabelValues(pocName, m, "hold")
	}
	metrics.ActiveWorkers.WithLabelValues(pocName)
}

// latencyCollector is a thread-safe store for latency samples (microseconds).
type latencyCollector struct {
	mu   sync.Mutex
	data []uint64
}

func (lc *latencyCollector) reset() {
	lc.mu.Lock()
	lc.data = lc.data[:0]
	lc.mu.Unlock()
}

func (lc *latencyCollector) observe(us uint64) {
	lc.mu.Lock()
	lc.data = append(lc.data, us)
	lc.mu.Unlock()
}

func (lc *latencyCollector) percentiles() (p50, p95, p99 float64) {
	lc.mu.Lock()
	vals := make([]uint64, len(lc.data))
	copy(vals, lc.data)
	lc.mu.Unlock()

	if len(vals) == 0 {
		return 0, 0, 0
	}
	sort.Slice(vals, func(i, j int) bool { return vals[i] < vals[j] })
	n := len(vals)
	// Convert microseconds to milliseconds
	return float64(vals[n*50/100]) / 1000,
		float64(vals[n*95/100]) / 1000,
		float64(vals[n*99/100]) / 1000
}

type stageResult struct {
	Workers   int
	Ops       int64
	OpsPerSec float64
	P50       float64 // ms
	P95       float64 // ms
	P99       float64 // ms
	ErrorRate float64
}

func main() {
	_ = godotenv.Load()

	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	fs.StringVar(&flagMode, "mode", "", "hset or bitfield (required)")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagSeats, "seats", 100000, "total seat count")
	fs.StringVar(&flagRamp, "ramp", "100,1000,5000,10000,25000,50000,100000", "comma-separated worker counts")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	fs.DurationVar(&flagStageDur, "stage-duration", 60*time.Second, "duration per ramp stage")
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
			slog.Error("metrics server error", "err", err)
		}
	}()

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		slog.Error("valkey client init failed", "err", err)
		os.Exit(1)
	}
	defer client.Close()

	scripts := loadScripts()

	slog.Info("starting POC 1 load test", "mode", flagMode, "seats", flagSeats, "stages", workerCounts)

	results := make([]stageResult, 0, len(workerCounts))
	for i, workers := range workerCounts {
		slog.Info("starting stage",
			"stage", i+1,
			"total_stages", len(workerCounts),
			"workers", workers,
		)
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

	latColl.reset()
	totalOps.Store(0)
	totalErrors.Store(0)

	start := time.Now()
	stopReport := make(chan struct{})
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				elapsed := time.Since(start).Seconds()
				ops := totalOps.Load()
				slog.Info("progress",
					"elapsed_s", fmt.Sprintf("%.0f", elapsed),
					"ops", ops,
					"ops_per_sec", fmt.Sprintf("%.0f", float64(ops)/elapsed),
					"errors", totalErrors.Load(),
				)
			case <-stopReport:
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
	close(stopReport)

	elapsed := time.Since(start)
	total := totalOps.Load() + totalErrors.Load()
	errRate := 0.0
	if total > 0 {
		errRate = float64(totalErrors.Load()) / float64(total)
	}

	opsPerSec := float64(totalOps.Load()) / elapsed.Seconds()
	p50, p95, p99 := latColl.percentiles()

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

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		seatIdx := r.Intn(flagSeats)
		opStart := time.Now()

		var success bool
		var execErr error

		switch flagMode {
		case "hset":
			key := "seats:event:1"
			seatID := fmt.Sprintf("seat:%05d", seatIdx+1)
			res := scripts.holdHSET.Exec(ctx, client,
				[]string{key},
				[]string{seatID, fmt.Sprintf("worker-%d", workerID), "60", strconv.FormatInt(time.Now().Unix(), 10)},
			)
			execErr = res.Error()
			if execErr == nil {
				if arr, err := res.ToArray(); err == nil && len(arr) > 0 {
					v, _ := arr[0].ToInt64()
					success = v == 1
				}
			}
		case "bitfield":
			bitsKey := "seats:event:1:bits"
			holdersKey := "seats:event:1:holders"
			res := scripts.holdBitfield.Exec(ctx, client,
				[]string{bitsKey, holdersKey},
				[]string{strconv.Itoa(seatIdx), fmt.Sprintf("worker-%d", workerID)},
			)
			execErr = res.Error()
			if execErr == nil {
				if arr, err := res.ToArray(); err == nil && len(arr) > 0 {
					v, _ := arr[0].ToInt64()
					success = v == 1
				}
			}
		}

		latencyUs := uint64(time.Since(opStart).Microseconds())
		latColl.observe(latencyUs)
		latencySec := float64(latencyUs) / 1e6

		if execErr != nil || !success {
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, flagMode, "error").Inc()
			time.Sleep(time.Millisecond)
			continue
		}

		totalOps.Add(1)
		metrics.OpsTotal.WithLabelValues(pocName, flagMode, "ok").Inc()
		metrics.LatencyHist.WithLabelValues(pocName, flagMode, "hold").Observe(latencySec)
	}
}

type loadedScripts struct {
	holdHSET     *valkey.Lua
	holdBitfield *valkey.Lua
}

func loadScripts() *loadedScripts {
	hsetSrc, err := os.ReadFile("lua/hold_hset.lua")
	if err != nil {
		slog.Error("failed to read lua/hold_hset.lua", "err", err)
		os.Exit(1)
	}
	bitfieldSrc, err := os.ReadFile("lua/hold_bitfield.lua")
	if err != nil {
		slog.Error("failed to read lua/hold_bitfield.lua", "err", err)
		os.Exit(1)
	}
	return &loadedScripts{
		holdHSET:     valkey.NewLuaScript(string(hsetSrc)),
		holdBitfield: valkey.NewLuaScript(string(bitfieldSrc)),
	}
}

func printStageResult(r stageResult) {
	slog.Info("stage result",
		"workers", r.Workers,
		"ops", r.Ops,
		"ops_per_sec", fmt.Sprintf("%.0f", r.OpsPerSec),
		"p50_ms", fmt.Sprintf("%.4f", r.P50),
		"p95_ms", fmt.Sprintf("%.4f", r.P95),
		"p99_ms", fmt.Sprintf("%.4f", r.P99),
		"error_rate_pct", fmt.Sprintf("%.2f", r.ErrorRate*100),
	)
}

func writeCSV(results []stageResult, mode string) {
	if err := os.MkdirAll("results", 0755); err != nil {
		slog.Error("mkdir results failed", "err", err)
		return
	}
	fname := fmt.Sprintf("results/%s-run.csv", mode)
	f, err := os.OpenFile(fname, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
	if err != nil {
		slog.Error("csv open failed", "file", fname, "err", err)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	_ = w.Write([]string{"workers", "ops", "ops_per_sec", "p50_ms", "p95_ms", "p99_ms", "error_rate"})
	for _, r := range results {
		_ = w.Write([]string{
			strconv.Itoa(r.Workers),
			strconv.FormatInt(r.Ops, 10),
			fmt.Sprintf("%.2f", r.OpsPerSec),
			fmt.Sprintf("%.4f", r.P50),
			fmt.Sprintf("%.4f", r.P95),
			fmt.Sprintf("%.4f", r.P99),
			fmt.Sprintf("%.6f", r.ErrorRate),
		})
	}
	w.Flush()
	if err := w.Error(); err != nil {
		slog.Error("csv flush error", "err", err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
