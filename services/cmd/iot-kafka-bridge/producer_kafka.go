package main

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
)

// kafkaProducer produces to the raw-telemetry Kafka topic (STREAM_RAW=msk). The
// original protobuf bytes are produced unmodified, keyed by VIN, with an ingest_ts
// header set to the receive time - unchanged from this bridge's behavior before the
// STREAM_RAW switch existed.
type kafkaProducer struct {
	cl    *kgo.Client
	topic string
	now   func() time.Time // overridden in tests; defaults to time.Now
}

func (p *kafkaProducer) Produce(ctx context.Context, vin string, raw []byte) error {
	now := time.Now
	if p.now != nil {
		now = p.now
	}
	rec := &kgo.Record{
		Topic: p.topic,
		Key:   []byte(vin),
		Value: raw, // original bytes, unmodified
		Headers: []kgo.RecordHeader{
			{Key: "ingest_ts", Value: []byte(strconv.FormatInt(now().UnixMilli(), 10))},
		},
	}
	if err := p.cl.ProduceSync(ctx, rec).FirstErr(); err != nil {
		return fmt.Errorf("produce to %s: %w", p.topic, err)
	}
	return nil
}
