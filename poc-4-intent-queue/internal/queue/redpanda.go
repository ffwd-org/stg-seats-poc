package queue

import (
	"context"
	"fmt"

	"github.com/twmb/franz-go/pkg/kgo"
)

// RedpandaProducer produces intents to Redpanda.
type RedpandaProducer struct {
	cl *kgo.Client
}

// NewRedpandaProducer creates a Redpanda producer.
// brokers: e.g. []string{"10.10.0.5:9092"}
func NewRedpandaProducer(ctx context.Context, brokers []string) (*RedpandaProducer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.DefaultProduceTopic("seat-holds"),
	)
	if err != nil {
		return nil, fmt.Errorf("redpanda producer: %w", err)
	}
	return &RedpandaProducer{cl: cl}, nil
}

func (p *RedpandaProducer) Produce(ctx context.Context, key []byte, value []byte) error {
	r := kgo.Record{
		Topic: "seat-holds",
		Key:   key,
		Value: value,
	}
	results := p.cl.ProduceSync(ctx, &r)
	for _, res := range results {
		if res.Err != nil {
			return fmt.Errorf("redpanda produce: %w", res.Err)
		}
	}
	return nil
}

func (p *RedpandaProducer) Close() error {
	p.cl.Close()
	return nil
}

// RedpandaConsumer consumes intents from Redpanda.
type RedpandaConsumer struct {
	cl *kgo.Client
}

func NewRedpandaConsumer(ctx context.Context, brokers []string, group string) (*RedpandaConsumer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics("seat-holds"),
		kgo.ConsumeResetOffset(kgo.NewOffsetAtEnd()),
	)
	if err != nil {
		return nil, fmt.Errorf("redpanda consumer: %w", err)
	}
	return &RedpandaConsumer{cl: cl}, nil
}

func (c *RedpandaConsumer) Poll(ctx context.Context, max int) ([]kgo.Record, error) {
	fetches := c.cl.PollFetches(ctx)
	var records []kgo.Record
	fetches.EachRecord(func(r kgo.Record) {
		records = append(records, r)
	})
	return records, nil
}

func (c *RedpandaConsumer) Close() error {
	c.cl.Close()
	return nil
}
