package queue

import (
	"context"
	"encoding/binary"
	"fmt"
	"sync"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/twmb/franz-go/pkg/kgo"
)

const redpandaTopic = "seat-holds"

// RedpandaProducer produces intents to Redpanda using async produce with acks=1.
type RedpandaProducer struct {
	cl *kgo.Client
	buf sync.Pool
}

// NewRedpandaProducer creates a Redpanda producer with acks=1 and 5ms linger.
func NewRedpandaProducer(_ context.Context, brokers []string) (*RedpandaProducer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.DefaultProduceTopic(redpandaTopic),
		kgo.RequiredAcks(kgo.LeaderAck()),
		kgo.ProducerLinger(5*time.Millisecond),
	)
	if err != nil {
		return nil, fmt.Errorf("redpanda producer: %w", err)
	}
	return &RedpandaProducer{
		cl: cl,
		buf: sync.Pool{New: func() any { b := make([]byte, intent.IntentSize); return &b }},
	}, nil
}

func (p *RedpandaProducer) Send(ctx context.Context, h *intent.HoldIntent) error {
	bp := p.buf.Get().(*[]byte)
	buf := *bp
	intent.Encode(h, buf)

	// Copy buf so we can return it to pool immediately
	value := make([]byte, intent.IntentSize)
	copy(value, buf)
	p.buf.Put(bp)

	// Key on EventID for partition affinity
	key := make([]byte, 8)
	binary.LittleEndian.PutUint64(key, h.EventID)

	r := &kgo.Record{
		Key:   key,
		Value: value,
	}

	errCh := make(chan error, 1)
	p.cl.Produce(ctx, r, func(_ *kgo.Record, err error) {
		errCh <- err
	})
	return <-errCh
}

func (p *RedpandaProducer) Close() error {
	p.cl.Close()
	return nil
}

// RedpandaConsumer consumes intents from Redpanda.
type RedpandaConsumer struct {
	cl *kgo.Client
}

func NewRedpandaConsumer(_ context.Context, brokers []string, group string) (*RedpandaConsumer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(redpandaTopic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()),
	)
	if err != nil {
		return nil, fmt.Errorf("redpanda consumer: %w", err)
	}
	return &RedpandaConsumer{cl: cl}, nil
}

func (c *RedpandaConsumer) FetchBatch(ctx context.Context, maxBatch int) ([]*intent.HoldIntent, error) {
	fetches := c.cl.PollFetches(ctx)
	if errs := fetches.Errors(); len(errs) > 0 {
		return nil, errs[0].Err
	}
	var intents []*intent.HoldIntent
	fetches.EachRecord(func(r *kgo.Record) {
		h, err := intent.Decode(r.Value)
		if err == nil {
			intents = append(intents, h)
		}
		if len(intents) >= maxBatch {
			return
		}
	})
	return intents, nil
}

func (c *RedpandaConsumer) Close() error {
	c.cl.Close()
	return nil
}
