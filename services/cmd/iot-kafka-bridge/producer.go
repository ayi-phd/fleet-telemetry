package main

import "context"

// RawProducer writes one decoded telemetry record to the raw stream. Implementations
// exist for Kafka (STREAM_RAW=msk) and Kinesis (STREAM_RAW=kinesis); this binary only
// runs on Floci after PLAN.md Phase 7 - real AWS routes IoT Core directly into the raw
// stream via a native rule action instead.
type RawProducer interface {
	Produce(ctx context.Context, vin string, raw []byte) error
}
