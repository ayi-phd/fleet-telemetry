// Package processor turns raw protobuf telemetry into canonical JSON events.
//
// Delivery semantics per poll batch (records of one VIN always share a partition,
// because IoT Core keys raw records by MQTT client id == VIN):
//  1. decode + validate (invalid -> DLQ), drop in-batch duplicates
//  2. one Redis pipeline: EXISTS dedup key + GET fleet mapping for every record
//  3. produce canonical events (+ DLQ records) and wait for acks
//  4. SET dedup keys with TTL
//  5. commit consumer offsets
//
// Marking dedup keys only after a successful produce means a crash can never
// drop a message; at worst it is re-emitted, and downstream consumers are
// idempotent on eventId.
package processor

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/redis/go-redis/v9"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
	"github.com/example/fleet-telemetry/internal/model"
	"github.com/example/fleet-telemetry/internal/platform"
)

var (
	recordsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "telemetry_processor_records_total",
		Help: "Raw records processed by outcome.",
	}, []string{"outcome"})
	batchSeconds = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "telemetry_processor_batch_seconds",
		Help:    "End-to-end batch processing latency.",
		Buckets: prometheus.DefBuckets,
	})
)

type Config struct {
	CanonicalTopic string
	DLQTopic       string
	DedupTTL       time.Duration
	MaxPollRecords int
}

type Processor struct {
	cfg Config
	cl  *kgo.Client
	rdb *redis.Client
	log *slog.Logger
}

func New(cfg Config, cl *kgo.Client, rdb *redis.Client, log *slog.Logger) *Processor {
	return &Processor{cfg: cfg, cl: cl, rdb: rdb, log: log}
}

func (p *Processor) Run(ctx context.Context) error {
	for {
		fetches := p.cl.PollRecords(ctx, p.cfg.MaxPollRecords)
		if fetches.IsClientClosed() || ctx.Err() != nil {
			return nil
		}
		fetches.EachError(func(topic string, part int32, err error) {
			p.log.Error("fetch error", "topic", topic, "partition", part, "err", err)
		})
		recs := fetches.Records()
		if len(recs) > 0 {
			start := time.Now()
			if err := platform.Retry(ctx, "process batch", func(ctx context.Context) error {
				return p.processBatch(ctx, recs)
			}); err != nil {
				return nil // context cancelled; offsets not committed, batch will be redelivered
			}
			batchSeconds.Observe(time.Since(start).Seconds())
		}
		p.cl.AllowRebalance()
	}
}

type item struct {
	ev       model.CanonicalEvent
	dedupKey string
}

func (p *Processor) processBatch(ctx context.Context, recs []*kgo.Record) error {
	now := time.Now()
	items := make([]item, 0, len(recs))
	var out []*kgo.Record
	seen := make(map[string]struct{}, len(recs))

	for _, rec := range recs {
		var msg telemetryv1.VehicleTelemetry
		if err := proto.Unmarshal(rec.Value, &msg); err != nil {
			out = append(out, p.dlq(rec, "decode: "+err.Error()))
			recordsTotal.WithLabelValues("invalid").Inc()
			continue
		}
		if err := model.Validate(&msg, now); err != nil {
			out = append(out, p.dlq(rec, "validate: "+err.Error()))
			recordsTotal.WithLabelValues("invalid").Inc()
			continue
		}
		key := platform.DedupKey(msg.GetVin(), msg.GetDeviceTimestamp())
		if _, dup := seen[key]; dup {
			recordsTotal.WithLabelValues("duplicate").Inc()
			continue
		}
		seen[key] = struct{}{}
		items = append(items, item{dedupKey: key, ev: model.CanonicalEvent{
			EventID:         model.EventID(msg.GetVin(), msg.GetDeviceTimestamp()),
			SchemaVersion:   model.SchemaVersion,
			VIN:             msg.GetVin(),
			Lng:             msg.GetLng(),
			Lat:             msg.GetLat(),
			Status:          model.StatusString(msg.GetStatus()),
			BatterySOC:      float64(msg.GetBatterySoc()),
			DeviceTimestamp: msg.GetDeviceTimestamp(),
			IngestTimestamp: ingestTimestamp(rec),
		}})
	}

	// Dedup check + fleet lookup in a single round trip.
	if len(items) > 0 {
		pipe := p.rdb.Pipeline()
		exists := make([]*redis.IntCmd, len(items))
		fleets := make([]*redis.StringCmd, len(items))
		for i := range items {
			exists[i] = pipe.Exists(ctx, items[i].dedupKey)
			fleets[i] = pipe.Get(ctx, platform.FleetKey(items[i].ev.VIN))
		}
		if _, err := pipe.Exec(ctx); err != nil && !errors.Is(err, redis.Nil) {
			return err
		}
		kept := items[:0]
		for i := range items {
			n, err := exists[i].Result()
			if err != nil {
				return err
			}
			if n > 0 {
				recordsTotal.WithLabelValues("duplicate").Inc()
				continue
			}
			fleet, err := fleets[i].Result()
			switch {
			case errors.Is(err, redis.Nil):
				fleet = model.UnassignedFleet
				recordsTotal.WithLabelValues("unassigned_vin").Inc()
			case err != nil:
				return err
			}
			items[i].ev.FleetID = fleet
			kept = append(kept, items[i])
		}
		items = kept
	}

	processedAt := time.Now().UnixMilli()
	for i := range items {
		items[i].ev.ProcessedTimestamp = processedAt
		b, err := json.Marshal(items[i].ev)
		if err != nil {
			return err
		}
		out = append(out, &kgo.Record{
			Topic:   p.cfg.CanonicalTopic,
			Key:     []byte(items[i].ev.VIN),
			Value:   b,
			Headers: []kgo.RecordHeader{{Key: "fleet_id", Value: []byte(items[i].ev.FleetID)}},
		})
	}

	if len(out) > 0 {
		if err := p.cl.ProduceSync(ctx, out...).FirstErr(); err != nil {
			return err
		}
	}

	if len(items) > 0 {
		pipe := p.rdb.Pipeline()
		for i := range items {
			pipe.Set(ctx, items[i].dedupKey, 1, p.cfg.DedupTTL)
		}
		if _, err := pipe.Exec(ctx); err != nil {
			// Not fatal: events are already published; worst case a later retry re-emits them.
			p.log.Warn("failed to record dedup keys", "err", err)
		}
		recordsTotal.WithLabelValues("published").Add(float64(len(items)))
	}

	return p.cl.CommitRecords(ctx, recs...)
}

func (p *Processor) dlq(rec *kgo.Record, reason string) *kgo.Record {
	return &kgo.Record{
		Topic: p.cfg.DLQTopic,
		Key:   rec.Key,
		Value: rec.Value,
		Headers: append(append([]kgo.RecordHeader{}, rec.Headers...),
			kgo.RecordHeader{Key: "error", Value: []byte(reason)},
			kgo.RecordHeader{Key: "source_partition", Value: []byte(strconv.Itoa(int(rec.Partition)))},
			kgo.RecordHeader{Key: "source_offset", Value: []byte(strconv.FormatInt(rec.Offset, 10))}),
	}
}

// ingestTimestamp prefers the IoT Core rule header (ms since epoch) over the Kafka record timestamp.
func ingestTimestamp(rec *kgo.Record) int64 {
	for _, h := range rec.Headers {
		if h.Key == "ingest_ts" {
			if v, err := strconv.ParseInt(string(h.Value), 10, 64); err == nil {
				return v
			}
		}
	}
	return rec.Timestamp.UnixMilli()
}
