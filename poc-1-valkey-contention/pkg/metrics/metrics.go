package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// OpsTotal counts seat hold operations by poc, mode, and result (ok/error).
	OpsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "poc_ops_total",
		Help: "Total seat hold operations partitioned by result",
	}, []string{"poc", "mode", "result"})

	// LatencyHist records operation latency in seconds.
	LatencyHist = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "poc_latency_seconds",
		Help:    "Seat hold operation latency in seconds",
		Buckets: []float64{.0005, .001, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"poc", "mode", "operation"})

	// ActiveWorkers tracks the number of active load generator goroutines.
	ActiveWorkers = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poc_active_workers",
		Help: "Number of active load generator goroutines",
	}, []string{"poc"})
)
