package queue

import (
	"context"
	"fmt"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

const (
	natsSubject    = "seats.holds"
	natsStreamName = "SEAT_HOLDS"
)

// NATSProducer produces intents to NATS JetStream.
type NATSProducer struct {
	nc *nats.Conn
	js jetstream.JetStream
}

// NewNATSProducer creates a NATS JetStream producer and ensures the stream exists.
func NewNATSProducer(ctx context.Context, url string) (*NATSProducer, error) {
	nc, err := nats.Connect(url)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("nats jetstream: %w", err)
	}

	// Ensure stream exists
	_, err = js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:     natsStreamName,
		Subjects: []string{natsSubject},
		MaxMsgs:  1_000_000,
	})
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("nats create stream: %w", err)
	}

	return &NATSProducer{nc: nc, js: js}, nil
}

func (p *NATSProducer) Send(ctx context.Context, h *intent.HoldIntent) error {
	buf := make([]byte, intent.IntentSize)
	intent.Encode(h, buf)
	_, err := p.js.Publish(ctx, natsSubject, buf)
	return err
}

func (p *NATSProducer) Close() error {
	p.nc.Close()
	return nil
}

// NATSConsumer consumes intents from NATS JetStream using pull-based consumption.
type NATSConsumer struct {
	nc  *nats.Conn
	con jetstream.Consumer
}

func NewNATSConsumer(ctx context.Context, url, consumerName string) (*NATSConsumer, error) {
	nc, err := nats.Connect(url)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("nats jetstream: %w", err)
	}

	con, err := js.CreateOrUpdateConsumer(ctx, natsStreamName, jetstream.ConsumerConfig{
		Durable:       consumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		DeliverPolicy: jetstream.DeliverNewPolicy,
		AckWait:       5 * time.Second,
	})
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("nats create consumer: %w", err)
	}

	return &NATSConsumer{nc: nc, con: con}, nil
}

func (c *NATSConsumer) FetchBatch(ctx context.Context, maxBatch int) ([]*intent.HoldIntent, error) {
	msgs, err := c.con.Fetch(maxBatch, jetstream.FetchMaxWait(time.Second))
	if err != nil {
		return nil, fmt.Errorf("nats fetch: %w", err)
	}

	var intents []*intent.HoldIntent
	for msg := range msgs.Messages() {
		h, decErr := intent.Decode(msg.Data())
		if decErr != nil {
			_ = msg.Nak()
			continue
		}
		_ = msg.Ack()
		intents = append(intents, h)
	}
	return intents, msgs.Error()
}

func (c *NATSConsumer) Close() error {
	c.nc.Close()
	return nil
}
