package queue

import (
	"context"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue/internal/intent"
	"github.com/valkey-io/valkey-go"
)

const valkeyStream = "seat:holds:stream"

// ValkeyStreamsProducer produces intents to Valkey Streams using XADD.
type ValkeyStreamsProducer struct {
	client valkey.Client
}

// NewValkeyStreamsProducer connects to the existing Valkey node.
func NewValkeyStreamsProducer(_ context.Context, addr string) (*ValkeyStreamsProducer, error) {
	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{addr}})
	if err != nil {
		return nil, fmt.Errorf("valkey streams producer: %w", err)
	}
	return &ValkeyStreamsProducer{client: client}, nil
}

func (p *ValkeyStreamsProducer) Send(ctx context.Context, h *intent.HoldIntent) error {
	buf := make([]byte, intent.IntentSize)
	intent.Encode(h, buf)
	encoded := hex.EncodeToString(buf)

	cmd := p.client.B().Xadd().Key(valkeyStream).Id("*").FieldValue().FieldValue("data", encoded).Build()
	return p.client.Do(ctx, cmd).Error()
}

func (p *ValkeyStreamsProducer) Close() error {
	p.client.Close()
	return nil
}

// ValkeyStreamsConsumer consumes from Valkey Streams via XREADGROUP.
type ValkeyStreamsConsumer struct {
	client   valkey.Client
	stream   string
	group    string
	consumer string
}

// NewValkeyStreamsConsumer creates a consumer group reader on the given stream.
func NewValkeyStreamsConsumer(ctx context.Context, addr, group, consumer string) (*ValkeyStreamsConsumer, error) {
	client, err := valkey.NewClient(valkey.ClientOption{InitAddress: []string{addr}})
	if err != nil {
		return nil, fmt.Errorf("valkey streams consumer: %w", err)
	}

	// Create consumer group if not exists (ignore error if already exists)
	createCmd := client.B().XgroupCreate().Key(valkeyStream).Group(group).Id("0").Mkstream().Build()
	_ = client.Do(ctx, createCmd).Error()

	return &ValkeyStreamsConsumer{
		client:   client,
		stream:   valkeyStream,
		group:    group,
		consumer: consumer,
	}, nil
}

func (c *ValkeyStreamsConsumer) FetchBatch(ctx context.Context, maxBatch int) ([]*intent.HoldIntent, error) {
	cmd := c.client.B().Xreadgroup().
		Group(c.group, c.consumer).
		Count(int64(maxBatch)).
		Block(time.Second.Milliseconds()).
		Streams().Key(c.stream).Id(">").
		Build()

	result, err := c.client.Do(ctx, cmd).AsXRead()
	if err != nil {
		// Timeout returns nil — not an error for us
		if valkey.IsValkeyNil(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("xreadgroup: %w", err)
	}

	var intents []*intent.HoldIntent
	for streamName, messages := range result {
		_ = streamName
		for _, msg := range messages {
			dataStr, ok := msg.FieldValues["data"]
			if !ok {
				continue
			}
			raw, decErr := hex.DecodeString(dataStr)
			if decErr != nil {
				continue
			}
			h, decErr := intent.Decode(raw)
			if decErr != nil {
				continue
			}
			intents = append(intents, h)
		}
	}
	return intents, nil
}

func (c *ValkeyStreamsConsumer) Close() error {
	c.client.Close()
	return nil
}
