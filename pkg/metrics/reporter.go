// Package metrics provides shared Prometheus metrics for all stg-seats POCs.
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// OpsTotal counts total operations executed, labelled by POC and result.
	OpsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "poc_ops_total",
		Help: "Total operations executed",
	}, []string{"poc", "result"})

	// LatencyHist records operation latency in seconds.
	LatencyHist = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "poc_latency_seconds",
		Help:    "Operation latency in seconds",
		Buckets: []float64{.0005, .001, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"poc", "operation"})

	// ActiveWorkers tracks the number of currently active worker goroutines.
	ActiveWorkers = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "poc_active_workers",
		Help: "Currently active worker goroutines",
	}, []string{"poc"})
)
