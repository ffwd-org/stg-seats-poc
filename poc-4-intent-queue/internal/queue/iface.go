package queue

import (
	"context"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
)

// Producer sends HoldIntents to a queue backend.
type Producer interface {
	Send(ctx context.Context, intent *intent.HoldIntent) error
	Close() error
}

// Consumer reads batches of HoldIntents from a queue backend.
type Consumer interface {
	// FetchBatch reads up to maxBatch intents, blocking up to the backend's
	// configured timeout. Returns the slice of decoded intents.
	FetchBatch(ctx context.Context, maxBatch int) ([]*intent.HoldIntent, error)
	Close() error
}
