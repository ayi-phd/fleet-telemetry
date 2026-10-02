package processor

import (
	"context"
	"time"
)

// RawHeader is one header on a raw record (Kafka headers only; always empty on the
// Kinesis path - see RawRecord).
type RawHeader struct {
	Key   string
	Value []byte
}

// RawRecord is one record from the raw stream, abstracted over its transport (Kafka,
// STREAM_RAW=msk, or Kinesis, STREAM_RAW=kinesis). Key is the VIN. Timestamp is the
// transport's own record timestamp - the Kafka broker timestamp, or a Kinesis
// record's ApproximateArrivalTimestamp - used as the ingest time whenever no
// ingest_ts header is present, which is always true on the Kinesis path (see
// ingestTimestamp in processor.go and PLAN.md Phase 7). Partition/Offset are a
// generic "where in the stream" pair (Kafka partition number + offset, or Kinesis
// shard ID + sequence number), carried through to DLQ records for diagnostics.
type RawRecord struct {
	Key       []byte
	Value     []byte
	Headers   []RawHeader
	Timestamp time.Time
	Partition string
	Offset    string
}

// RawBatch is a batch of records polled together, plus whatever transport-specific
// state (e.g. the original *kgo.Record pointers, or per-shard sequence numbers) its
// RawConsumer needs in order to check the batch off once it's been handled. Processor
// never looks inside raw; it's opaque outside the RawConsumer that produced it.
type RawBatch struct {
	Records []RawRecord
	raw     any
}

// RawConsumer abstracts reading the raw stream and acknowledging progress on it, so
// Processor's produce -> dedup -> checkpoint loop doesn't need to know whether the
// raw stream is Kafka or Kinesis.
type RawConsumer interface {
	// Poll blocks until a batch of records is available, ctx is done, or the
	// consumer should stop for some other reason (ok=false means stop the Run
	// loop; an empty-but-ok batch is normal and simply skipped).
	Poll(ctx context.Context) (batch RawBatch, ok bool)
	// Checkpoint acknowledges that every record in batch has been produced
	// downstream and deduped. Must only be called after both have succeeded -
	// preserves the existing "produce -> dedup -> commit" ordering invariant.
	Checkpoint(ctx context.Context, batch RawBatch) error
}
