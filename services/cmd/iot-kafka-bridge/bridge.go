package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"google.golang.org/protobuf/proto"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
)

// bridgeHandler implements lambda.Handler directly (Invoke(ctx, []byte) ([]byte,
// error)) rather than a typed function, so aws-lambda-go hands it the invocation
// payload as raw bytes instead of running it through encoding/json first.
type bridgeHandler struct {
	producer RawProducer
	log      *slog.Logger
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

// Invoke produces the original protobuf bytes, unmodified, keyed by VIN, to whichever
// raw stream this bridge is configured for (see RawProducer). Returning an error
// makes IoT Core retry the invocation.
func (h *bridgeHandler) Invoke(ctx context.Context, payload []byte) ([]byte, error) {
	raw, vin, err := decodePayload(payload)
	if err != nil {
		h.log.Error("decode failed", "err", err, "payload_b64", base64.StdEncoding.EncodeToString(payload))
		return nil, err
	}

	if err := h.producer.Produce(ctx, vin, raw); err != nil {
		return nil, fmt.Errorf("produce: %w", err)
	}

	h.log.Info("forwarded telemetry", "vin", vin)
	return nil, nil
}
