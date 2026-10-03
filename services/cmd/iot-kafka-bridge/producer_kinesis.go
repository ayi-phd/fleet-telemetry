package main

import (
	"context"
	"fmt"

	"github.com/example/fleet-telemetry/internal/platform"
)

// kinesisProducer produces to the raw-telemetry Kinesis stream (STREAM_RAW=kinesis).
// No header or envelope: unlike Kafka, a Kinesis PutRecord has nowhere to carry a
// custom ingest_ts, so telemetry-processor relies entirely on the record's own
// ApproximateArrivalTimestamp instead (see PLAN.md Phase 7). The VIN is still the
// partition key, so a vehicle's reports stay on one shard.
type kinesisProducer struct {
	kin    *platform.Kinesis
	stream string
}

func (p *kinesisProducer) Produce(ctx context.Context, vin string, raw []byte) error {
	if err := p.kin.PutRecord(ctx, p.stream, vin, raw); err != nil {
		return fmt.Errorf("put record to %s: %w", p.stream, err)
	}
	return nil
}
