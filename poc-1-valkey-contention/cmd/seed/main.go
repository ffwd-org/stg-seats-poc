package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/valkey-io/valkey-go"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("seed failed", "err", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("seed", flag.ContinueOnError)
	mode := fs.String("mode", "both", "hset, bitfield, or both")
	seats := fs.Int("seats", 100000, "number of seats to seed")
	valkeyAddr := fs.String("valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	if err := fs.Parse(args); err != nil {
		return err
	}

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{*valkeyAddr}})
	if err != nil {
		return fmt.Errorf("valkey client: %w", err)
	}
	defer client.Close()

	const pipeSize = 500

	switch *mode {
	case "hset":
		return seedHSET(ctx, client, *seats, pipeSize)
	case "bitfield":
		return seedBitfield(ctx, client, *seats, pipeSize)
	case "both":
		if err := seedHSET(ctx, client, *seats, pipeSize); err != nil {
			return err
		}
		return seedBitfield(ctx, client, *seats, pipeSize)
	default:
		return fmt.Errorf("unknown mode: %s (use hset, bitfield, or both)", *mode)
	}
}

func seedHSET(ctx context.Context, client valkey.Client, seats, pipeSize int) error {
	start := time.Now()
	key := "seats:event:1"
	slog.Info("seeding HSET", "seats", seats, "key", key)

	for idx := 0; idx < seats; idx += pipeSize {
		end := idx + pipeSize
		if end > seats {
			end = seats
		}
		cmds := make([]valkey.Completed, 0, end-idx)
		for i := idx; i < end; i++ {
			cmds = append(cmds, client.B().Hset().Key(key).
				FieldValue().FieldValue(fmt.Sprintf("seat:%05d", i+1), "available").
				Build())
		}
		for _, res := range client.DoMulti(ctx, cmds...) {
			if err := res.Error(); err != nil {
				return fmt.Errorf("hset seed: %w", err)
			}
		}
		if idx%10000 == 0 {
			slog.Info("seeded batch", "from", idx, "to", end)
		}
	}

	elapsed := time.Since(start)
	slog.Info("HSET seed complete",
		"seats", seats,
		"duration", elapsed,
		"ops_per_sec", fmt.Sprintf("%.0f", float64(seats)/elapsed.Seconds()),
	)
	return nil
}

func seedBitfield(ctx context.Context, client valkey.Client, seats, pipeSize int) error {
	start := time.Now()
	bitsKey := "seats:event:1:bits"
	holdersKey := "seats:event:1:holders"
	slog.Info("seeding BITFIELD", "seats", seats, "key", bitsKey)

	// Clear existing data
	if err := client.Do(ctx, client.B().Del().Key(bitsKey).Key(holdersKey).Build()).Error(); err != nil {
		slog.Warn("DEL warning (key may not exist)", "err", err)
	}

	// Initialize: 100k seats × 2 bits = 25000 bytes. Pre-set the key to zeroed bytes.
	byteCount := (seats*2 + 7) / 8
	zeros := make([]byte, byteCount)
	if err := client.Do(ctx, client.B().Set().Key(bitsKey).Value(string(zeros)).Build()).Error(); err != nil {
		return fmt.Errorf("bitfield init: %w", err)
	}

	elapsed := time.Since(start)
	slog.Info("BITFIELD seed complete",
		"seats", seats,
		"bits_key_bytes", strconv.Itoa(byteCount),
		"duration", elapsed,
	)
	_ = holdersKey // holders key is empty on seed; created on first hold
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
