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

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"

	"github.com/ffwd-org/stg-seats-poc/pkg/metrics"
)

const pocName = "poc1"

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("loadgen failed", "err", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("loadgen", flag.ContinueOnError)
	mode := fs.String("mode", "", "hset or bitfield (required)")
	valkeyAddr := fs.String("valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	seats := fs.Int("seats", 100000, "total seat count")
	ramp := fs.String("ramp", "100,1000,5000,10000,25000,50000,100000", "comma-separated worker counts")
	metricsPort := fs.Int("metrics-port", 2112, "Prometheus metrics port")
	stageDur := fs.Duration("stage-duration", 60*time.Second, "duration per ramp stage")
	cooldown := fs.Duration("cooldown", 10*time.Second, "pause between stages")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *mode == "" {
		return fmt.Errorf("--mode is required (hset or bitfield)")
	}

	workerCounts, err := parseRamp(*ramp)
	if err != nil {
		return fmt.Errorf("parsing --ramp: %w", err)
	}

	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		addr := fmt.Sprintf(":%d", *metricsPort)
		slog.Info("metrics server listening", "addr", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			slog.Error("metrics server error", "err", err)
		}
	}()

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.ClientOption{
		InitAddress: []string{*valkeyAddr},
	})
	if err != nil {
		return fmt.Errorf("valkey client: %w", err)
	}
	defer client.Close()

	scripts, err := loadScripts()
	if err != nil {
		return fmt.Errorf("loading scripts: %w", err)
	}

	if err := client.Do(ctx, client.B().Ping().Build()).Error(); err != nil {
		return fmt.Errorf("valkey ping: %w", err)
	}

	// Pre-register label sets.
	// OpsTotal uses labels {"poc", "result"} per pkg/metrics/reporter.go
	// LatencyHist uses labels {"poc", "operation"} per pkg/metrics/reporter.go
	// ActiveWorkers uses labels {"poc"}
	metrics.OpsTotal.WithLabelValues(pocName, "ok")
	metrics.OpsTotal.WithLabelValues(pocName, "error")
	metrics.OpsTotal.WithLabelValues(pocName, "contention")
	metrics.LatencyHist.WithLabelValues(pocName, "hold")
	metrics.ActiveWorkers.WithLabelValues(pocName)

	slog.Info("starting load test", "mode", *mode, "seats", *seats, "stages", workerCounts)

	var results []stageResult
	for i, workers := range workerCounts {
		slog.Info("starting stage", "stage", i+1, "of", len(workerCounts), "workers", workers)
		res := runStage(ctx, client, workers, scripts, *mode, *seats, *stageDur)
		results = append(results, res)
		printStageResult(res)
		writeCSV(results, *mode)

		if i < len(workerCounts)-1 && *cooldown > 0 {
			slog.Info("cooldown", "duration", *cooldown)
			time.Sleep(*cooldown)
		}
	}

	slog.Info("all stages complete")
	return nil
}

type stageResult struct {
	Workers      int
	DurationSec  float64
	TotalOps     int64
	OpsPerSec    float64
	P50Ms        float64
	P95Ms        float64
	P99Ms        float64
	Errors       int64
	ValkeyCPUPct float64
}

type latencyStore struct {
	mu      sync.Mutex
	samples []float64
	cap     int
}

func newLatencyStore(cap int) *latencyStore {
	return &latencyStore{samples: make([]float64, 0, cap), cap: cap}
}

func (s *latencyStore) add(v float64) {
	s.mu.Lock()
	if len(s.samples) < s.cap {
		s.samples = append(s.samples, v)
	}
	s.mu.Unlock()
}

func (s *latencyStore) reset() {
	s.mu.Lock()
	s.samples = s.samples[:0]
	s.mu.Unlock()
}

func (s *latencyStore) percentiles() (p50, p95, p99 float64) {
	s.mu.Lock()
	vals := make([]float64, len(s.samples))
	copy(vals, s.samples)
	s.mu.Unlock()
	if len(vals) == 0 {
		return 0, 0, 0
	}
	sort.Float64s(vals)
	n := len(vals)
	return vals[n*50/100], vals[n*95/100], vals[n*99/100]
}

var lats = newLatencyStore(2_000_000)

func runStage(ctx context.Context, client valkey.Client, nWorkers int, scripts *loadedScripts, mode string, seatCount int, dur time.Duration) stageResult {
	metrics.ActiveWorkers.WithLabelValues(pocName).Set(float64(nWorkers))
	lats.reset()

	var totalOps, totalErrors atomic.Int64

	cpuBefore := getValkeyCPU(ctx, client)
	start := time.Now()

	stageCtx, cancel := context.WithTimeout(ctx, dur)
	defer cancel()

	doneCh := make(chan struct{})
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
					"ops_s", fmt.Sprintf("%.0f", float64(ops)/elapsed),
					"errors", totalErrors.Load(),
				)
			case <-doneCh:
				return
			}
		}
	}()

	var wg sync.WaitGroup
	for i := 0; i < nWorkers; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			runWorker(stageCtx, client, id, scripts, mode, seatCount, &totalOps, &totalErrors)
		}(i)
	}
	wg.Wait()
	close(doneCh)

	elapsed := time.Since(start)
	cpuAfter := getValkeyCPU(ctx, client)
	cpuPct := 0.0
	if elapsed.Seconds() > 0 && cpuAfter > cpuBefore {
		cpuPct = ((cpuAfter - cpuBefore) / elapsed.Seconds()) * 100
	}

	ops := totalOps.Load()
	errs := totalErrors.Load()
	p50, p95, p99 := lats.percentiles()

	metrics.ActiveWorkers.WithLabelValues(pocName).Set(0)

	return stageResult{
		Workers:      nWorkers,
		DurationSec:  elapsed.Seconds(),
		TotalOps:     ops,
		OpsPerSec:    float64(ops) / elapsed.Seconds(),
		P50Ms:        p50 * 1000,
		P95Ms:        p95 * 1000,
		P99Ms:        p99 * 1000,
		Errors:       errs,
		ValkeyCPUPct: cpuPct,
	}
}

func runWorker(ctx context.Context, client valkey.Client, workerID int, scripts *loadedScripts, mode string, seatCount int, totalOps, totalErrors *atomic.Int64) {
	r := rand.New(rand.NewSource(int64(workerID) ^ time.Now().UnixNano()))
	holderID := fmt.Sprintf("worker-%d", workerID)

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		seatIdx := r.Intn(seatCount)
		opStart := time.Now()

		var code int64
		var execErr error

		switch mode {
		case "hset":
			res := scripts.holdHSET.Exec(ctx, client,
				[]string{"seats:event:1"},
				[]string{
					fmt.Sprintf("seat:%05d", seatIdx+1),
					holderID,
					"60",
					strconv.FormatInt(time.Now().Unix(), 10),
				},
			)
			if execErr = res.Error(); execErr == nil {
				arr, e := res.ToArray()
				if e != nil {
					execErr = e
				} else if len(arr) > 0 {
					code, _ = arr[0].ToInt64()
				}
			}
		case "bitfield":
			res := scripts.holdBitfield.Exec(ctx, client,
				[]string{"seats:event:1:bits", "seats:event:1:holders"},
				[]string{strconv.Itoa(seatIdx), holderID},
			)
			if execErr = res.Error(); execErr == nil {
				arr, e := res.ToArray()
				if e != nil {
					execErr = e
				} else if len(arr) > 0 {
					code, _ = arr[0].ToInt64()
				}
			}
		}

		latency := time.Since(opStart).Seconds()
		lats.add(latency)
		metrics.LatencyHist.WithLabelValues(pocName, "hold").Observe(latency)

		if execErr != nil {
			totalErrors.Add(1)
			metrics.OpsTotal.WithLabelValues(pocName, "error").Inc()
			continue
		}
		if code == 0 {
			metrics.OpsTotal.WithLabelValues(pocName, "contention").Inc()
			continue
		}

		totalOps.Add(1)
		metrics.OpsTotal.WithLabelValues(pocName, "ok").Inc()
	}
}

type loadedScripts struct {
	holdHSET     *valkey.Lua
	holdBitfield *valkey.Lua
}

func loadScripts() (*loadedScripts, error) {
	hsetSrc, err := os.ReadFile("lua/hold_hset.lua")
	if err != nil {
		return nil, fmt.Errorf("reading hold_hset.lua: %w", err)
	}
	bitfieldSrc, err := os.ReadFile("lua/hold_bitfield.lua")
	if err != nil {
		return nil, fmt.Errorf("reading hold_bitfield.lua: %w", err)
	}
	return &loadedScripts{
		holdHSET:     valkey.NewLuaScript(string(hsetSrc)),
		holdBitfield: valkey.NewLuaScript(string(bitfieldSrc)),
	}, nil
}

func getValkeyCPU(ctx context.Context, client valkey.Client) float64 {
	raw, err := client.Do(ctx, client.B().Arbitrary("INFO", "stats").Build()).ToString()
	if err != nil {
		return 0
	}
	var cpuSys, cpuUser float64
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "used_cpu_sys:"):
			fmt.Sscanf(strings.TrimPrefix(line, "used_cpu_sys:"), "%f", &cpuSys)
		case strings.HasPrefix(line, "used_cpu_user:"):
			fmt.Sscanf(strings.TrimPrefix(line, "used_cpu_user:"), "%f", &cpuUser)
		}
	}
	return cpuSys + cpuUser
}

func printStageResult(r stageResult) {
	slog.Info("stage result",
		"workers", r.Workers,
		"total_ops", r.TotalOps,
		"ops_per_sec", fmt.Sprintf("%.0f", r.OpsPerSec),
		"p50_ms", fmt.Sprintf("%.3f", r.P50Ms),
		"p95_ms", fmt.Sprintf("%.3f", r.P95Ms),
		"p99_ms", fmt.Sprintf("%.3f", r.P99Ms),
		"errors", r.Errors,
		"valkey_cpu_pct", fmt.Sprintf("%.1f", r.ValkeyCPUPct),
	)
}

func writeCSV(results []stageResult, mode string) {
	if err := os.MkdirAll("results", 0o755); err != nil {
		slog.Error("mkdir results", "err", err)
		return
	}
	fname := fmt.Sprintf("results/%s-run.csv", mode)
	f, err := os.OpenFile(fname, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		slog.Error("csv open", "err", err, "file", fname)
		return
	}
	defer f.Close()
	w := csv.NewWriter(f)
	_ = w.Write([]string{
		"workers", "duration_sec", "total_ops", "ops_per_sec",
		"p50_latency_ms", "p95_latency_ms", "p99_latency_ms",
		"errors", "valkey_cpu_pct",
	})
	for _, r := range results {
		_ = w.Write([]string{
			strconv.Itoa(r.Workers),
			fmt.Sprintf("%.2f", r.DurationSec),
			strconv.FormatInt(r.TotalOps, 10),
			fmt.Sprintf("%.2f", r.OpsPerSec),
			fmt.Sprintf("%.3f", r.P50Ms),
			fmt.Sprintf("%.3f", r.P95Ms),
			fmt.Sprintf("%.3f", r.P99Ms),
			strconv.FormatInt(r.Errors, 10),
			fmt.Sprintf("%.2f", r.ValkeyCPUPct),
		})
	}
	w.Flush()
	if err := w.Error(); err != nil {
		slog.Error("csv flush", "err", err)
	}
}

func parseRamp(s string) ([]int, error) {
	var result []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid worker count %q: %w", part, err)
		}
		result = append(result, n)
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no worker counts in ramp string")
	}
	return result, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
