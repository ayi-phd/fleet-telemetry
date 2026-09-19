package router

import (
	"context"
	"encoding/json"
	"log/slog"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
	"github.com/example/fleet-telemetry/internal/platform"
)

// RunPush consumes canonical events in its own consumer group and dispatches them
// to connected dashboard-api streams. It favours latency over completeness: it starts
// at the log end and skips events older than maxAge (e.g. after a restart).
func RunPush(ctx context.Context, kc platform.KafkaConfig, topic, group string, maxAge time.Duration, hub *Hub, log *slog.Logger) error {
	cl, err := kgo.NewClient(append(kc.Opts(),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()),
		kgo.AutoCommitInterval(2*time.Second),
		kgo.FetchMaxWait(100*time.Millisecond),
	)...)
	if err != nil {
		return err
	}
	defer cl.Close()

	for {
		fetches := cl.PollFetches(ctx)
		if fetches.IsClientClosed() || ctx.Err() != nil {
			return nil
		}
		fetches.EachError(func(t string, p int32, err error) {
			log.Error("push fetch error", "topic", t, "partition", p, "err", err)
		})
		cutoff := time.Now().Add(-maxAge)
		fetches.EachRecord(func(r *kgo.Record) {
			if r.Timestamp.Before(cutoff) {
				return
			}
			var ids struct {
				VIN     string `json:"vin"`
				FleetID string `json:"fleetId"`
			}
			if err := json.Unmarshal(r.Value, &ids); err != nil {
				log.Warn("unparseable canonical event", "err", err)
				return
			}
			hub.Dispatch(&routerv1.TelemetryEvent{Vin: ids.VIN, FleetId: ids.FleetID, CanonicalJson: r.Value})
		})
	}
}
