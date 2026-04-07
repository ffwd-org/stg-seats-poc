//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/joho/godotenv"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/valkey-io/valkey-go"
)

const pocName = "poc4-direct"

var (
	flagPort        int
	flagValkeyAddr string
	flagMetricsPort int
	valkeyClient   valkey.Client
	holdScript     *valkey.Script
)

func main() {
	godotenv.Load()

	fs := flag.NewFlagSet("direct", flag.ContinueOnError)
	fs.IntVar(&flagPort, "port", 8080, "HTTP server port")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagMetricsPort, "metrics-port", 2112, "Prometheus metrics port")
	if err := fs.Parse(nil); err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	var err error
	valkeyClient, err = valkey.NewClient(valkey.Option{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		log.Fatalf("valkey client: %v", err)
	}
	defer valkeyClient.Close()

	holdSrc, _ := os.ReadFile("lua/hold_seat.lua")
	holdScript = valkey.NewScript(string(holdSrc))

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Printf("Metrics on :%d/metrics", flagMetricsPort)
		http.ListenAndServe(fmt.Sprintf(":%d", flagMetricsPort), nil)
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/hold", handleHold)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })

	addr := fmt.Sprintf(":%d", flagPort)
	log.Printf("Direct-to-Valkey server on %s → %s", addr, flagValkeyAddr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Printf("server: %v", err)
	}
}

func handleHold(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		EventID    uint64 `json:"event_id"`
		SeatID     uint64 `json:"seat_id"`
		HoldToken  string `json:"hold_token"`
		TTLSeconds uint32 `json:"ttl_seconds"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	seatKey := fmt.Sprintf("seats:event:%d", req.EventID)
	seatID := fmt.Sprintf("seat:%05d", req.SeatID)
	now := uint64(time.Now().Unix())

	result, err := holdScript.Exec(ctx, valkeyClient,
		[]string{seatKey},
		[]interface{}{seatID, req.HoldToken, req.TTLSeconds, now}).ToString()
	if err != nil {
		log.Printf("hold error: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	if result == "seat_unavailable" {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprintln(w, `{"ok":false,"reason":"seat_unavailable"}`)
		return
	}

	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `{"ok":true,"seat":"%s"}`, seatID)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
