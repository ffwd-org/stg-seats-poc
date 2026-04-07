//go:build ignore

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/joho/godotenv"
	"github.com/valkey-io/valkey-go"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		log.Fatalf("seed failed: %v", err)
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
	client, err := valkey.NewClient(valkey.Option{InitAddress: []string{*valkeyAddr}})
	if err != nil {
		return fmt.Errorf("valkey client: %w", err)
	}
	defer client.Close()

	pipeSize := 10000

	switch *mode {
	case "hset":
		return seedHSET(ctx, client, *seats, pipeSize)
	case "bitfield":
		return seedBitfield(ctx, client, *seats, pipeSize)
	case "both":
		if err := seedHSET(ctx, client, *seats, pipeSize); err != nil {
			return err
		}
		fmt.Println()
		if err := seedBitfield(ctx, client, *seats, pipeSize); err != nil {
			return err
		}
		return nil
	default:
		return fmt.Errorf("unknown mode: %s (use hset, bitfield, or both)", *mode)
	}
}

func seedHSET(ctx context.Context, client valkey.Client, seats, pipeSize int) error {
	start := time.Now()
	key := "seats:event:1"

	log.Printf("Seeding %d seats as HSET on key %q...", seats, key)

	for idx := 0; idx < seats; idx += pipeSize {
		end := idx + pipeSize
		if end > seats {
			end = seats
		}
		pipe := client.B()
		for i := idx; i < end; i++ {
			pipe.HSet(key, fmt.Sprintf("seat:%05d", i+1), "available")
		}
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("hset seed: %w", err)
		}
	}

	client.Flush(ctx)
	elapsed := time.Since(start)
	opsPerSec := float64(seats) / elapsed.Seconds()
	log.Printf("HSET seed complete: %d seats in %.2fs (%.0f ops/sec)", seats, elapsed.Seconds(), opsPerSec)
	return nil
}

func seedBitfield(ctx context.Context, client valkey.Client, seats, pipeSize int) error {
	start := time.Now()
	bitsKey := "seats:event:1:bits"
	holdersKey := "seats:event:1:holders"

	log.Printf("Seeding %d seats as BITFIELD (2 bits/seat) on key %q...", seats, bitsKey)

	// Clear any existing data
	if _, err := client.Do(ctx, client.B().Del(bitsKey, holdersKey).Payload()).Result(); err != nil {
		log.Printf("DEL warning (key may not exist): %v", err)
	}

	for idx := 0; idx < seats; idx += pipeSize {
		end := idx + pipeSize
		if end > seats {
			end = seats
		}
		pipe := client.B()
		for i := idx; i < end; i++ {
			// Set 2 bits at offset i*2 to value 0 (available)
			pipe.BitField(bitsKey, "SET", "u2", i*2, 0)
		}
		if _, err := pipe.Exec(ctx); err != nil {
			return fmt.Errorf("bitfield seed: %w", err)
		}
	}

	client.Flush(ctx)
	elapsed := time.Since(start)
	opsPerSec := float64(seats) / elapsed.Seconds()
	log.Printf("BITFIELD seed complete: %d seats in %.2fs (%.0f ops/sec)", seats, elapsed.Seconds(), opsPerSec)
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
