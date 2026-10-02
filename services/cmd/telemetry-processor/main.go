package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/example/fleet-telemetry/internal/platform"
	"github.com/example/fleet-telemetry/internal/processor"
)

func main() {
	log := platform.NewLogger("telemetry-processor")
	ctx, stop := platform.SignalContext()
	defer stop()

	health := &platform.Health{}
	go platform.ServeOps(ctx, platform.Env("OPS_ADDR", ":8081"), health)

	rawTopic := platform.Env("RAW_TOPIC", "raw-telemetry")
	canonicalTopic := platform.Env("CANONICAL_TOPIC", "canonical-events")
	dlqTopic := platform.Env("DLQ_TOPIC", "raw-telemetry-dlq")
	streamRaw := platform.Env("STREAM_RAW", "msk")
	maxPollRecords := platform.EnvInt("MAX_POLL_RECORDS", 1000)

	// cl always produces canonical-events/DLQ, which stay on Kafka regardless of
	// STREAM_RAW (see PLAN.md Phase 7); it also consumes raw-telemetry itself when
	// STREAM_RAW=msk, same as before the switch existed.
	kc := platform.KafkaConfigFromEnv()
	clOpts := append(kc.Opts(),
		kgo.ProducerLinger(5*time.Millisecond),
		kgo.ProducerBatchCompression(kgo.Lz4Compression()),
	)
	if streamRaw != "kinesis" {
		clOpts = append(clOpts,
			kgo.ConsumerGroup(platform.Env("CONSUMER_GROUP", "telemetry-processor")),
			kgo.ConsumeTopics(rawTopic),
			kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
			kgo.DisableAutoCommit(),
			kgo.BlockRebalanceOnPoll(),
		)
	}
	cl, err := kgo.NewClient(clOpts...)
	if err != nil {
		log.Error("kafka client", "err", err)
		os.Exit(1)
	}
	defer cl.Close()

	partitions := int32(platform.EnvInt("TOPIC_PARTITIONS", 6))
	replication := int16(platform.EnvInt("TOPIC_REPLICATION", 3))
	retention := platform.EnvDuration("TOPIC_RETENTION", 72*time.Hour)
	minInsyncReplicas := platform.EnvInt("TOPIC_MIN_INSYNC_REPLICAS", 2)
	topics := []string{canonicalTopic, dlqTopic}
	if streamRaw != "kinesis" {
		// On the kinesis path, raw-telemetry is a Kinesis stream, a real Terraform
		// resource - not a Kafka topic for this (or anything else) to create.
		topics = append(topics, rawTopic)
	}
	if err := platform.Retry(ctx, "ensure topics", func(ctx context.Context) error {
		return platform.EnsureTopics(ctx, cl, partitions, replication, retention, minInsyncReplicas, topics...)
	}); err != nil {
		return
	}

	rdb := platform.NewRedis()
	defer rdb.Close()
	if err := platform.Retry(ctx, "redis ping", func(ctx context.Context) error {
		return rdb.Ping(ctx).Err()
	}); err != nil {
		return
	}

	raw, err := newRawConsumer(ctx, streamRaw, cl, maxPollRecords, rdb, log)
	if err != nil {
		log.Error("raw consumer", "err", err)
		return
	}

	p := processor.New(processor.Config{
		CanonicalTopic: canonicalTopic,
		DLQTopic:       dlqTopic,
		DedupTTL:       platform.EnvDuration("DEDUP_TTL", time.Hour),
	}, raw, cl, rdb, log)

	health.SetReady(true)
	log.Info("telemetry-processor started", "stream_raw", streamRaw, "canonical", canonicalTopic)
	if err := p.Run(ctx); err != nil {
		log.Error("processor stopped", "err", err)
	}
	health.SetReady(false)
	log.Info("telemetry-processor stopped")
}

// newRawConsumer picks a processor.RawConsumer based on streamRaw (default "msk",
// today's behavior). cl is reused as the Kafka raw consumer's client on the msk path
// (it's already configured with the right ConsumerGroup/ConsumeTopics options); the
// kinesis path needs its own Kinesis client and stream name instead.
func newRawConsumer(ctx context.Context, streamRaw string, cl *kgo.Client, maxPollRecords int, rdb *redis.Client, log *slog.Logger) (processor.RawConsumer, error) {
	if streamRaw == "kinesis" {
		kin, err := platform.NewKinesis(ctx, platform.MustEnv("AWS_REGION"))
		if err != nil {
			return nil, err
		}
		return processor.NewKinesisRawConsumer(ctx, kin, platform.MustEnv("RAW_STREAM_NAME"), maxPollRecords, rdb, log)
	}
	return processor.NewKafkaRawConsumer(cl, maxPollRecords, log), nil
}
