package main

import (
	"context"
	"os"
	"time"

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

	kc := platform.KafkaConfigFromEnv()
	cl, err := kgo.NewClient(append(kc.Opts(),
		kgo.ConsumerGroup(platform.Env("CONSUMER_GROUP", "telemetry-processor")),
		kgo.ConsumeTopics(rawTopic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.DisableAutoCommit(),
		kgo.BlockRebalanceOnPoll(),
		kgo.ProducerLinger(5*time.Millisecond),
		kgo.ProducerBatchCompression(kgo.Lz4Compression()),
	)...)
	if err != nil {
		log.Error("kafka client", "err", err)
		os.Exit(1)
	}
	defer cl.Close()

	partitions := int32(platform.EnvInt("TOPIC_PARTITIONS", 6))
	replication := int16(platform.EnvInt("TOPIC_REPLICATION", 3))
	retention := platform.EnvDuration("TOPIC_RETENTION", 72*time.Hour)
	minInsyncReplicas := platform.EnvInt("TOPIC_MIN_INSYNC_REPLICAS", 2)
	if err := platform.Retry(ctx, "ensure topics", func(ctx context.Context) error {
		return platform.EnsureTopics(ctx, cl, partitions, replication, retention, minInsyncReplicas, rawTopic, canonicalTopic, dlqTopic)
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

	p := processor.New(processor.Config{
		CanonicalTopic: canonicalTopic,
		DLQTopic:       dlqTopic,
		DedupTTL:       platform.EnvDuration("DEDUP_TTL", time.Hour),
		MaxPollRecords: platform.EnvInt("MAX_POLL_RECORDS", 1000),
	}, cl, rdb, log)

	health.SetReady(true)
	log.Info("telemetry-processor started", "raw", rawTopic, "canonical", canonicalTopic)
	if err := p.Run(ctx); err != nil {
		log.Error("processor stopped", "err", err)
	}
	health.SetReady(false)
	log.Info("telemetry-processor stopped")
}
