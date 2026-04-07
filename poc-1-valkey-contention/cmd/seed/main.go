package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/joho/godotenv"
	"github.com/valkey-io/valkey-go"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		slog.Error("seed failed", "err", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	godotenv.Load()

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

	const pipeSize = 5000

	switch *mode {
	case "hset":
		return seedHSET(ctx, client, *seats, pipeSize)
	case "bitfield":
		return seedBitfield(ctx, client, *seats)
	case "both":
		if err := seedHSET(ctx, client, *seats, pipeSize); err != nil {
			return err
		}
		return seedBitfield(ctx, client, *seats)
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
		// Build one HSET command with all field-value pairs in this batch
		fv := client.B().Hset().Key(key).FieldValue()
		for i := idx; i < end; i++ {
			fv = fv.FieldValue(fmt.Sprintf("seat:%05d", i+1), "available")
		}
		if err := client.Do(ctx, fv.Build()).Error(); err != nil {
			return fmt.Errorf("hset seed batch %d-%d: %w", idx, end, err)
		}
	}

	elapsed := time.Since(start)
	slog.Info("HSET seed complete", "seats", seats, "elapsed", elapsed, "ops_per_sec", float64(seats)/elapsed.Seconds())
	return nil
}

func seedBitfield(ctx context.Context, client valkey.Client, seats int) error {
	start := time.Now()
	bitsKey := "seats:event:1:bits"
	holdersKey := "seats:event:1:holders"

	slog.Info("seeding BITFIELD", "seats", seats, "bits_key", bitsKey)

	// Clear any existing data
	if err := client.Do(ctx, client.B().Del().Key(bitsKey, holdersKey).Build()).Error(); err != nil {
		slog.Warn("DEL warning (key may not exist)", "err", err)
	}

	// Pre-allocate the bitfield string by setting the last seat's offset.
	// All bits default to 0 (available) after DEL; this just sizes the string correctly.
	lastOffset := int64((seats - 1) * 2)
	cmd := client.B().Arbitrary("BITFIELD").Keys(bitsKey).
		Args("SET", "u2", fmt.Sprintf("%d", lastOffset), "0").Build()
	if err := client.Do(ctx, cmd).Error(); err != nil {
		return fmt.Errorf("bitfield preallocate: %w", err)
	}

	elapsed := time.Since(start)
	slog.Info("BITFIELD seed complete", "seats", seats, "elapsed", elapsed,
		"memory_bytes_approx", (seats*2+7)/8)
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
