package queue

import (
	"context"
	"fmt"
	"time"

	"github.com/valkey-io/valkey-go"
)

// ValkeyStreamsProducer produces intents to Valkey Streams.
type ValkeyStreamsProducer struct {
	client valkey.Client
}

// NewValkeyStreamsProducer connects to the existing Valkey node.
func NewValkeyStreamsProducer(ctx context.Context, addr string) (*ValkeyStreamsProducer, error) {
	client, err := valkey.NewClient(valkey.Option{InitAddress: []string{addr}})
	if err != nil {
		return nil, fmt.Errorf("valkey streams producer: %w", err)
	}
	return &ValkeyStreamsProducer{client: client}, nil
}

func (p *ValkeyStreamsProducer) XAdd(ctx context.Context, stream, id string, fields map[string]interface{}) error {
	return p.client.XAdd(ctx, &valkey.XAddArgs{
		Stream: stream,
		ID:     id,
		Values: fields,
	}).Err()
}

func (p *ValkeyStreamsProducer) Close() error {
	p.client.Close()
	return nil
}

// ValkeyStreamsConsumer consumes from Valkey Streams via XREADGROUP.
type ValkeyStreamsConsumer struct {
	client valkey.Client
	group  string
}

// NewValkeyStreamsConsumer creates a consumer group reader on the given stream.
func NewValkeyStreamsConsumer(ctx context.Context, addr, stream, group, consumer string) (*ValkeyStreamsConsumer, error) {
	client, err := valkey.NewClient(valkey.Option{InitAddress: []string{addr}})
	if err != nil {
		return nil, fmt.Errorf("valkey streams consumer: %w", err)
	}
	// Create consumer group if not exists
	client.XGroupCreateMkStream(ctx, stream, group, "0")
	return &ValkeyStreamsConsumer{client: client, group: group}, nil
}

// ReadGroup reads new messages from the stream.
// Returns messages in format: []string{key, value, key, value, ...}
func (c *ValkeyStreamsConsumer) ReadGroup(ctx context.Context, stream, consumer string, count int64) ([]string, error) {
	result, err := c.client.XReadGroup(ctx, &valkey.XReadGroupArgs{
		Streams:  []string{stream, ">"},
		Groups:   []string{c.group + " " + consumer},
		Count:    count,
		Block:    time.Second,
	}).ToMap()
	if err != nil {
		return nil, err
	}

	var flat []string
	for streamName, messages := range result {
		_ = streamName
		for _, msg := range messages {
			flat = append(flat, msg.ID)
			flat = append(flat, msg.Values["data"])
		}
	}
	return flat, nil
}

func (c *ValkeyStreamsConsumer) Close() error {
	c.client.Close()
	return nil
}
