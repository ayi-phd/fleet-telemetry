package router

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/example/fleet-telemetry/internal/model"
	"github.com/example/fleet-telemetry/internal/platform"
)

var indexedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
	Name: "realtime_router_indexed_total", Help: "Documents written to OpenSearch by outcome.",
}, []string{"outcome"})

// Persister writes canonical events to daily OpenSearch indices using its own
// consumer group, so slow indexing never delays live push. Offsets are committed
// only after a successful bulk request (at-least-once); documents use eventId as
// _id, which makes redelivery idempotent.
type Persister struct {
	OS            *platform.OpenSearch
	IndexPrefix   string
	IndexReplicas int // 0 on Floci's single-node domain, which can't allocate a replica shard
	Log           *slog.Logger
}

const indexTemplate = `{
  "index_patterns": ["%s-*"],
  "template": {
    "settings": {"number_of_shards": 1, "number_of_replicas": %d, "refresh_interval": "2s"},
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "eventId":            {"type": "keyword"},
        "schemaVersion":      {"type": "integer"},
        "vin":                {"type": "keyword"},
        "fleetId":            {"type": "keyword"},
        "status":             {"type": "keyword"},
        "batterySOC":         {"type": "float"},
        "lat":                {"type": "double"},
        "lng":                {"type": "double"},
        "location":           {"type": "geo_point"},
        "deviceTimestamp":    {"type": "date", "format": "epoch_millis"},
        "ingestTimestamp":    {"type": "date", "format": "epoch_millis"},
        "processedTimestamp": {"type": "date", "format": "epoch_millis"}
      }
    }
  }
}`

func (p *Persister) EnsureTemplate(ctx context.Context) error {
	code, body, err := p.OS.Do(ctx, "PUT", "/_index_template/"+p.IndexPrefix,
		[]byte(fmt.Sprintf(indexTemplate, p.IndexPrefix, p.IndexReplicas)), "")
	if err != nil {
		return err
	}
	if code >= 300 {
		return fmt.Errorf("index template: HTTP %d: %s", code, body)
	}
	return nil
}

func (p *Persister) Run(ctx context.Context, kc platform.KafkaConfig, topic, group string) error {
	cl, err := kgo.NewClient(append(kc.Opts(),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(topic),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
		kgo.DisableAutoCommit(),
		kgo.BlockRebalanceOnPoll(),
	)...)
	if err != nil {
		return err
	}
	defer cl.Close()

	for {
		fetches := cl.PollRecords(ctx, 2000)
		if fetches.IsClientClosed() || ctx.Err() != nil {
			return nil
		}
		fetches.EachError(func(t string, part int32, err error) {
			p.Log.Error("persist fetch error", "topic", t, "partition", part, "err", err)
		})
		recs := fetches.Records()
		if len(recs) > 0 {
			body := p.buildBulk(recs)
			if err := platform.Retry(ctx, "opensearch bulk", func(ctx context.Context) error {
				return p.bulk(ctx, body)
			}); err != nil {
				return nil
			}
			if err := cl.CommitRecords(ctx, recs...); err != nil {
				p.Log.Warn("offset commit failed; batch may be re-indexed", "err", err)
			}
		}
		cl.AllowRebalance()
	}
}

type indexedDoc struct {
	model.CanonicalEvent
	Location struct {
		Lat float64 `json:"lat"`
		Lon float64 `json:"lon"`
	} `json:"location"`
}

func (p *Persister) buildBulk(recs []*kgo.Record) []byte {
	var buf bytes.Buffer
	for _, r := range recs {
		var doc indexedDoc
		if err := json.Unmarshal(r.Value, &doc.CanonicalEvent); err != nil || doc.EventID == "" {
			indexedTotal.WithLabelValues("skipped").Inc()
			continue
		}
		doc.Location.Lat, doc.Location.Lon = doc.Lat, doc.Lng
		index := p.IndexPrefix + "-" + time.UnixMilli(doc.DeviceTimestamp).UTC().Format("2006.01.02")
		meta, _ := json.Marshal(map[string]any{"index": map[string]string{"_index": index, "_id": doc.EventID}})
		src, _ := json.Marshal(doc)
		buf.Write(meta)
		buf.WriteByte('\n')
		buf.Write(src)
		buf.WriteByte('\n')
	}
	return buf.Bytes()
}

func (p *Persister) bulk(ctx context.Context, body []byte) error {
	if len(body) == 0 {
		return nil
	}
	code, resp, err := p.OS.Do(ctx, "POST", "/_bulk", body, "application/x-ndjson")
	if err != nil {
		return err
	}
	if code == 429 || code >= 500 {
		return fmt.Errorf("bulk HTTP %d", code)
	}
	if code >= 300 {
		p.Log.Error("bulk request rejected; dropping batch", "status", code, "body", truncate(resp))
		indexedTotal.WithLabelValues("rejected").Inc()
		return nil
	}
	var r struct {
		Errors bool `json:"errors"`
		Items  []map[string]struct {
			Status int             `json:"status"`
			Error  json.RawMessage `json:"error"`
		} `json:"items"`
	}
	if err := json.Unmarshal(resp, &r); err != nil {
		return err
	}
	ok, failed := 0, 0
	for _, it := range r.Items {
		for _, res := range it {
			switch {
			case res.Status == 429 || res.Status >= 500:
				return fmt.Errorf("retryable item error (status %d)", res.Status) // whole batch retried; idempotent
			case res.Status >= 300:
				failed++
				p.Log.Error("document rejected", "status", res.Status, "error", truncate(res.Error))
			default:
				ok++
			}
		}
	}
	indexedTotal.WithLabelValues("indexed").Add(float64(ok))
	indexedTotal.WithLabelValues("rejected").Add(float64(failed))
	return nil
}

func truncate(b []byte) string {
	if len(b) > 512 {
		return string(b[:512]) + "..."
	}
	return string(b)
}
