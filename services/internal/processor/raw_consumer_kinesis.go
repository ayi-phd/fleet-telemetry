package processor

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/example/fleet-telemetry/internal/platform"
)

// kinesisCheckpointPrefix namespaces per-shard checkpoints in Redis, which is already
// a dependency (used for dedup) - Kinesis has no consumer-group/offset-commit concept
// of its own, so checkpoints are stored here instead (see PLAN.md Phase 7).
const kinesisCheckpointPrefix = "kinesis:checkpoint:"

// pollInterval is how long kinesisRawConsumer waits before polling again when a
// round found no new records on any shard, to stay well under Kinesis's per-shard
// GetRecords rate limit.
const pollInterval = time.Second

// kinesisRawConsumer reads the raw-telemetry Kinesis stream (STREAM_RAW=kinesis),
// polling every shard each round and checkpointing per-shard sequence numbers in
// Redis after a batch has been produced and deduped. Live resharding (shard splits
// or merges after startup) is a known, accepted gap - not handled here (PLAN.md
// Phase 7): shards are listed once, at construction.
type kinesisRawConsumer struct {
	kin            *platform.Kinesis
	stream         string
	rdb            *redis.Client
	log            *slog.Logger
	maxPollRecords int32

	iterators map[string]string // shardID -> next shard iterator; "" once a shard has closed for good
}

// NewKinesisRawConsumer lists the stream's shards and seeds an iterator for each one
// (resuming from a saved Redis checkpoint, or TRIM_HORIZON on a shard never read
// before).
func NewKinesisRawConsumer(ctx context.Context, kin *platform.Kinesis, stream string, maxPollRecords int, rdb *redis.Client, log *slog.Logger) (RawConsumer, error) {
	shardIDs, err := kin.ListShards(ctx, stream)
	if err != nil {
		return nil, err
	}
	c := &kinesisRawConsumer{
		kin: kin, stream: stream, rdb: rdb, log: log,
		maxPollRecords: int32(maxPollRecords),
		iterators:      make(map[string]string, len(shardIDs)),
	}
	for _, id := range shardIDs {
		after, err := c.checkpointFor(ctx, id)
		if err != nil {
			return nil, err
		}
		it, err := kin.ShardIterator(ctx, stream, id, after)
		if err != nil {
			return nil, err
		}
		c.iterators[id] = it
	}
	return c, nil
}

func (c *kinesisRawConsumer) checkpointKey(shardID string) string {
	return kinesisCheckpointPrefix + shardID
}

func (c *kinesisRawConsumer) checkpointFor(ctx context.Context, shardID string) (string, error) {
	v, err := c.rdb.Get(ctx, c.checkpointKey(shardID)).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil // no checkpoint yet; ShardIterator falls back to TRIM_HORIZON
	}
	return v, err
}

func (c *kinesisRawConsumer) Poll(ctx context.Context) (RawBatch, bool) {
	if ctx.Err() != nil {
		return RawBatch{}, false
	}

	var batch RawBatch
	checkpoints := make(map[string]string, len(c.iterators))

	for shardID, it := range c.iterators {
		if it == "" {
			continue // shard closed for good (e.g. after a reshard)
		}
		recs, nextIt, err := c.kin.GetRecords(ctx, it, c.maxPollRecords)
		if err != nil {
			c.log.Error("get records", "shard", shardID, "err", err)
			continue
		}
		c.iterators[shardID] = nextIt
		if len(recs) == 0 {
			continue
		}
		checkpoints[shardID] = recs[len(recs)-1].SequenceNumber
		for _, r := range recs {
			batch.Records = append(batch.Records, RawRecord{
				Key:       []byte(r.PartitionKey),
				Value:     r.Data,
				Headers:   nil, // Kinesis has no header concept; see ingestTimestamp
				Timestamp: r.ApproximateArrivalTimestamp,
				Partition: shardID,
				Offset:    r.SequenceNumber,
			})
		}
	}
	batch.raw = checkpoints

	if len(batch.Records) == 0 {
		select {
		case <-ctx.Done():
			return RawBatch{}, false
		case <-time.After(pollInterval):
		}
	}
	return batch, true
}

func (c *kinesisRawConsumer) Checkpoint(ctx context.Context, batch RawBatch) error {
	checkpoints, _ := batch.raw.(map[string]string)
	if len(checkpoints) == 0 {
		return nil
	}
	pipe := c.rdb.Pipeline()
	for shardID, seq := range checkpoints {
		pipe.Set(ctx, c.checkpointKey(shardID), seq, 0) // no TTL: checkpoints must persist indefinitely
	}
	_, err := pipe.Exec(ctx)
	return err
}
