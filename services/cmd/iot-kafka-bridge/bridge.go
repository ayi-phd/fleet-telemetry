package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
)

// bridgeHandler implements lambda.Handler directly (Invoke(ctx, []byte) ([]byte,
// error)) rather than a typed function, so aws-lambda-go hands it the invocation
// payload as raw bytes instead of running it through encoding/json first.
type bridgeHandler struct {
	cl    *kgo.Client
	topic string
	log   *slog.Logger
	now   func() time.Time // overridden in tests; defaults to time.Now
}

// envelope matches the JSON form some IoT rule SQL variants produce instead of
// delivering raw bytes, e.g. `SELECT encode(*, 'base64') AS payload FROM
// 'fleet/telemetry'` (see PLAN.md Phase 4).
type envelope struct {
	Payload string `json:"payload"`
}

// decodePayload accepts either raw protobuf bytes or a JSON envelope carrying a
// base64-encoded "payload" field, and returns the raw protobuf bytes (unmodified)
// together with the VIN read from them.
func decodePayload(payload []byte) (raw []byte, vin string, err error) {
	raw = payload
	var env envelope
	if jerr := json.Unmarshal(payload, &env); jerr == nil && env.Payload != "" {
		decoded, derr := base64.StdEncoding.DecodeString(env.Payload)
		if derr != nil {
			return nil, "", fmt.Errorf("decode base64 payload: %w", derr)
		}
		raw = decoded
	}

	var msg telemetryv1.VehicleTelemetry
	if err := proto.Unmarshal(raw, &msg); err != nil {
		return nil, "", fmt.Errorf("decode telemetry protobuf: %w", err)
	}
	if msg.GetVin() == "" {
		return nil, "", errors.New("telemetry payload has no VIN")
	}
	return raw, msg.GetVin(), nil
}

// Invoke produces the original protobuf bytes to Kafka unmodified, keyed by VIN,
// with an ingest_ts header set to the receive time. Returning an error makes IoT
// Core retry the invocation.
func (h *bridgeHandler) Invoke(ctx context.Context, payload []byte) ([]byte, error) {
	raw, vin, err := decodePayload(payload)
	if err != nil {
		h.log.Error("decode failed", "err", err, "payload_b64", base64.StdEncoding.EncodeToString(payload))
		return nil, err
	}

	now := time.Now
	if h.now != nil {
		now = h.now
	}
	rec := &kgo.Record{
		Topic: h.topic,
		Key:   []byte(vin),
		Value: raw, // original bytes, unmodified
		Headers: []kgo.RecordHeader{
			{Key: "ingest_ts", Value: []byte(strconv.FormatInt(now().UnixMilli(), 10))},
		},
	}
	if err := h.cl.ProduceSync(ctx, rec).FirstErr(); err != nil {
		return nil, fmt.Errorf("produce to %s: %w", h.topic, err)
	}

	h.log.Info("forwarded telemetry", "vin", vin, "topic", h.topic)
	return nil, nil
}
