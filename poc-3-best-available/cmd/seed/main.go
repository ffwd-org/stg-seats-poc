//go:build ignore

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strings"

	"github.com/joho/godotenv"
	"github.com/valkey-io/valkey-go"
)

const (
	Sections  = 20
	RowsPerSection = 100
	SeatsPerRow   = 50
	TotalSeats    = Sections * RowsPerSection * SeatsPerRow // 100,000
)

var (
	flagMode         string
	flagValkeyAddr   string
	flagFragmentation int
)

func main() {
	godotenv.Load()

	fs := flag.NewFlagSet("seed", flag.ContinueOnError)
	fs.StringVar(&flagMode, "mode", "both", "hset, bitfield, or both")
	fs.StringVar(&flagValkeyAddr, "valkey-addr", envOr("VALKEY_ADDR", "localhost:6379"), "Valkey address")
	fs.IntVar(&flagFragmentation, "fragmentation", 0, "0-100: percent of seats to pre-hold (random)")
	if err := fs.Parse(os.Args[1:]); err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	client, err := valkey.NewClient(valkey.Option{InitAddress: []string{flagValkeyAddr}})
	if err != nil {
		log.Fatalf("valkey client: %v", err)
	}
	defer client.Close()

	// Build venue layout
	layout := buildVenue()

	// Seed layout keys (shared across modes)
	if err := seedLayout(ctx, client, layout); err != nil {
		log.Fatalf("layout seed: %v", err)
	}

	// Optionally pre-hold some seats for fragmentation testing
	if flagFragmentation > 0 {
		if err := applyFragmentation(ctx, client, layout); err != nil {
			log.Fatalf("fragmentation: %v", err)
		}
	}

	switch flagMode {
	case "hset":
		if err := seedHSET(ctx, client, layout); err != nil {
			log.Fatal(err)
		}
	case "bitfield":
		if err := seedBitfield(ctx, client, layout); err != nil {
			log.Fatal(err)
		}
	case "both":
		if err := seedHSET(ctx, client, layout); err != nil {
			log.Fatal(err)
		}
		fmt.Println()
		if err := seedBitfield(ctx, client, layout); err != nil {
			log.Fatal(err)
		}
	default:
		log.Fatalf("unknown mode: %s", flagMode)
	}
}

// Venue layout: section → row → [seatIds]
type Venue struct {
	Seats map[string]map[string][]string // section → row → seatIds
	All   []string
}

func buildVenue() *Venue {
	v := &Venue{Seats: make(map[string]map[string][]string), All: make([]string, 0, TotalSeats)}
	sectionRune := 'A'
	for s := 0; s < Sections; s++ {
		secName := fmt.Sprintf("%c", sectionRune+s)
		v.Seats[secName] = make(map[string][]string)
		for r := 1; r <= RowsPerSection; r++ {
			rowName := fmt.Sprintf("%s-%d", secName, r)
			row := make([]string, SeatsPerRow)
			for i := 1; i <= SeatsPerRow; i++ {
				seatID := fmt.Sprintf("seat:%05d", len(v.All)+1)
				row[i-1] = seatID
				v.All = append(v.All, seatID)
			}
			v.Seats[secName][rowName] = row
		}
	}
	return v
}

func seedLayout(ctx context.Context, client valkey.Client, layout *Venue) error {
	pipe := client.BrPopPush(ctx, 0)
	defer client.Close()

	// seats:event:1 — status HSET
	// venue:event:1:layout — seatId → {section,row,index}
	// venue:event:1:rows — rowName → comma-sep seatIds

	pipe.HSet(ctx, "seats:event:1", "placeholder", "available")
	pipe.HDel(ctx, "seats:event:1", "placeholder")

	for secName, rows := range layout.Seats {
		for rowName, seatIds := range rows {
			pipe.HSet(ctx, "venue:event:1:rows", rowName, strings.Join(seatIds, ","))
			for i, seatID := range seatIds {
				pipe.HSet(ctx, "seats:event:1", seatID, "available")
				pipe.HSet(ctx, "venue:event:1:layout", seatID,
					fmt.Sprintf("%s:%s:%d", secName, rowName, i))
			}
		}
	}

	if err := pipe.Drain(ctx); err != nil {
		return fmt.Errorf("layout seed: %w", err)
	}
	log.Printf("Layout seeded: %d seats across %d sections × %d rows × %d seats",
		TotalSeats, Sections, RowsPerSection, SeatsPerRow)
	return nil
}

func seedHSET(ctx context.Context, client valkey.Client, layout *Venue) error {
	log.Printf("Seeding HSET format (%d seats)...", TotalSeats)
	pipe := client.BrPopPush(ctx, 0)
	for _, seatID := range layout.All {
		pipe.HSet(ctx, "seats:event:1", seatID, "available")
	}
	if err := pipe.Drain(ctx); err != nil {
		return fmt.Errorf("hset seed: %w", err)
	}
	log.Printf("HSET seeded: %d seats", TotalSeats)
	return nil
}

func seedBitfield(ctx context.Context, client valkey.Client, layout *Venue) error {
	log.Printf("Seeding BITFIELD format (2 bits/seat, %d total bits)...", TotalSeats*2)
	// BITFIELD: no explicit init needed — Valkey auto-zeros on first SET
	pipe := client.BrPopPush(ctx, 0)
	for i := range layout.All {
		pipe.BitField(ctx, "seats:event:1:bits",
			"SET", "u2", i*2, 0) // 0 = available
	}
	if err := pipe.Drain(ctx); err != nil {
		return fmt.Errorf("bitfield seed: %w", err)
	}
	log.Printf("BITFIELD seeded: %d seats (2 bits each)", TotalSeats)
	return nil
}

func applyFragmentation(ctx context.Context, client valkey.Client, layout *Venue) error {
	holdCount := TotalSeats * flagFragmentation / 100
	log.Printf("Applying %.0f%% fragmentation: %d seats pre-held...", float64(flagFragmentation), holdCount)

	r := rand.New(rand.NewSource(42)) // deterministic
	shuffled := make([]string, len(layout.All))
	copy(shuffled, layout.All)
	r.Shuffle(len(shuffled), func(i, j int) { shuffled[i], shuffled[j] = shuffled[j], shuffled[i] })

	pipe := client.BrPopPush(ctx, 0)
	for i := 0; i < holdCount; i++ {
		seatID := shuffled[i]
		pipe.HSet(ctx, "seats:event:1", seatID, "held:fragmentation-seed")
	}
	if err := pipe.Drain(ctx); err != nil {
		return fmt.Errorf("fragmentation seed: %w", err)
	}
	log.Printf("Fragmentation applied: %d seats held", holdCount)
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
