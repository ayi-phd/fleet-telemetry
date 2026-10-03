package processor

import (
	"context"
	"log/slog"
	"strconv"

	"github.com/twmb/franz-go/pkg/kgo"
)

// kafkaRawConsumer reads the raw-telemetry Kafka topic (STREAM_RAW=msk) - unchanged
// behavior from before the STREAM_RAW switch existed: same consumer group, same
// DisableAutoCommit/CommitRecords flow, same AllowRebalance call after each batch.
type kafkaRawConsumer struct {
	cl             *kgo.Client
	maxPollRecords int
	log            *slog.Logger
}

// NewKafkaRawConsumer wraps cl (already configured with ConsumerGroup/ConsumeTopics/
// DisableAutoCommit/BlockRebalanceOnPoll) as a RawConsumer. cl is the same client
// Processor uses to produce canonical-events/DLQ - today's behavior, unchanged.
func NewKafkaRawConsumer(cl *kgo.Client, maxPollRecords int, log *slog.Logger) RawConsumer {
	return &kafkaRawConsumer{cl: cl, maxPollRecords: maxPollRecords, log: log}
}

func (k *kafkaRawConsumer) Poll(ctx context.Context) (RawBatch, bool) {
	fetches := k.cl.PollRecords(ctx, k.maxPollRecords)
	if fetches.IsClientClosed() || ctx.Err() != nil {
		return RawBatch{}, false
	}
	fetches.EachError(func(topic string, part int32, err error) {
		k.log.Error("fetch error", "topic", topic, "partition", part, "err", err)
	})

	recs := fetches.Records()
	batch := RawBatch{Records: make([]RawRecord, len(recs)), raw: recs}
	for i, r := range recs {
		batch.Records[i] = RawRecord{
			Key:       r.Key,
			Value:     r.Value,
			Headers:   fromKgoHeaders(r.Headers),
			Timestamp: r.Timestamp,
			Partition: strconv.Itoa(int(r.Partition)),
			Offset:    strconv.FormatInt(r.Offset, 10),
		}
	}
	return batch, true
}

func (k *kafkaRawConsumer) Checkpoint(ctx context.Context, batch RawBatch) error {
	defer k.cl.AllowRebalance()
	recs, _ := batch.raw.([]*kgo.Record)
	return k.cl.CommitRecords(ctx, recs...)
}

func fromKgoHeaders(hs []kgo.RecordHeader) []RawHeader {
	if len(hs) == 0 {
		return nil
	}
	out := make([]RawHeader, len(hs))
	for i, h := range hs {
		out[i] = RawHeader{Key: h.Key, Value: h.Value}
	}
	return out
}

func toKgoHeaders(hs []RawHeader) []kgo.RecordHeader {
	out := make([]kgo.RecordHeader, len(hs))
	for i, h := range hs {
		out[i] = kgo.RecordHeader{Key: h.Key, Value: h.Value}
	}
	return out
}
