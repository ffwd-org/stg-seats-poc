package queue

import (
	"context"
	"fmt"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// NATSProducer produces intents to NATS JetStream.
type NATSProducer struct {
	js jetstream.JetStream
}

// NewNATSProducer creates a NATS JetStream producer.
// url: e.g. "nats://10.10.0.5:4222"
func NewNATSProducer(ctx context.Context, url string) (*NATSProducer, error) {
	nc, err := nats.Connect(url)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("nats jetstream: %w", err)
	}
	return &NATSProducer{js: js}, nil
}

func (p *NATSProducer) Publish(ctx context.Context, subject string, data []byte) error {
	_, err := p.js.Publish(ctx, subject, data)
	return err
}

func (p *NATSProducer) Close() error {
	return nil
}

// NATSConsumer consumes intents from NATS JetStream.
type NATSConsumer struct {
	js      jetstream.JetStream
	stream  string
	subject string
}

func NewNATSStream(ctx context.Context, url, streamName, subject string) error {
	nc, err := nats.Connect(url)
	if err != nil {
		return fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		return fmt.Errorf("nats jetstream: %w", err)
	}

	// Ensure stream exists
	s, _ := js.Stream(ctx, streamName)
	if s == nil {
		_, err = js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
			Name:     streamName,
			Subjects: []string{subject},
			MaxMsgs:  1_000_000,
		})
		if err != nil {
			return fmt.Errorf("create stream: %w", err)
		}
	}
	return nil
}

func NewNATSConsumer(ctx context.Context, url, streamName, consumerName string) (*NATSConsumer, error) {
	nc, err := nats.Connect(url)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("nats jetstream: %w", err)
	}
	return &NATSConsumer{js: js, stream: streamName}, nil
}

func (c *NATSConsumer) Consume(ctx context.Context, handler func(data []byte) error) error {
	cons, err := c.js.Consume(ctx, c.stream, jetstream.ConsumeConfig{
		// Pull-based consumer for batch efficiency
	})
	if err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg := <-cons.Messages():
			if err := handler(msg.Data()); err != nil {
				msg.Nak()
				continue
			}
			msg.Ack()
		}
	}
}
