package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kfake"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
)

func testTelemetry(vin string) []byte {
	b, err := proto.Marshal(&telemetryv1.VehicleTelemetry{
		Vin:             vin,
		Lat:             37.77,
		Lng:             -122.41,
		Status:          telemetryv1.VehicleStatus_VEHICLE_STATUS_DRIVING,
		BatterySoc:      55,
		DeviceTimestamp: time.Now().UnixMilli(),
	})
	if err != nil {
		panic(err)
	}
	return b
}

func TestDecodePayload_RawProtobuf(t *testing.T) {
	want := testTelemetry("SIM00000000000001")

	raw, vin, err := decodePayload(want)
	if err != nil {
		t.Fatalf("decodePayload: %v", err)
	}
	if vin != "SIM00000000000001" {
		t.Errorf("vin = %q, want SIM00000000000001", vin)
	}
	if string(raw) != string(want) {
		t.Errorf("raw bytes were modified: got %x, want %x", raw, want)
	}
}

func TestDecodePayload_JSONEnvelope(t *testing.T) {
	want := testTelemetry("SIM00000000000002")
	env, err := json.Marshal(struct {
		Payload string `json:"payload"`
	}{Payload: base64.StdEncoding.EncodeToString(want)})
	if err != nil {
		t.Fatal(err)
	}

	raw, vin, err := decodePayload(env)
	if err != nil {
		t.Fatalf("decodePayload: %v", err)
	}
	if vin != "SIM00000000000002" {
		t.Errorf("vin = %q, want SIM00000000000002", vin)
	}
	if string(raw) != string(want) {
		t.Errorf("raw bytes differ from the enveloped protobuf: got %x, want %x", raw, want)
	}
}

func TestDecodePayload_NoVIN(t *testing.T) {
	msg := testTelemetry("")
	if _, _, err := decodePayload(msg); err == nil {
		t.Fatal("expected an error for a telemetry payload with no VIN")
	}
}

func TestDecodePayload_InvalidProtobuf(t *testing.T) {
	if _, _, err := decodePayload([]byte("not a protobuf message")); err == nil {
		t.Fatal("expected an error for an undecodable payload")
	}
}

func TestDecodePayload_InvalidBase64Envelope(t *testing.T) {
	env, _ := json.Marshal(struct {
		Payload string `json:"payload"`
	}{Payload: "not-base64!!"})
	if _, _, err := decodePayload(env); err == nil {
		t.Fatal("expected an error for an unparsable base64 envelope payload")
	}
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func TestInvoke_ProducesUnmodifiedRecord(t *testing.T) {
	cluster, err := kfake.NewCluster(kfake.SeedTopics(1, "raw-telemetry"))
	if err != nil {
		t.Fatalf("kfake.NewCluster: %v", err)
	}
	defer cluster.Close()

	cl, err := kgo.NewClient(kgo.SeedBrokers(cluster.ListenAddrs()...))
	if err != nil {
		t.Fatalf("kgo.NewClient: %v", err)
	}
	defer cl.Close()

	fixedNow := time.UnixMilli(1_700_000_000_000)
	h := &bridgeHandler{cl: cl, topic: "raw-telemetry", log: quietLogger(), now: func() time.Time { return fixedNow }}

	payload := testTelemetry("SIM00000000000003")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := h.Invoke(ctx, payload); err != nil {
		t.Fatalf("Invoke: %v", err)
	}

	consumer, err := kgo.NewClient(
		kgo.SeedBrokers(cluster.ListenAddrs()...),
		kgo.ConsumeTopics("raw-telemetry"),
		kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()),
	)
	if err != nil {
		t.Fatalf("kgo.NewClient (consumer): %v", err)
	}
	defer consumer.Close()

	fetches := consumer.PollRecords(ctx, 1)
	if err := fetches.Err(); err != nil {
		t.Fatalf("PollRecords: %v", err)
	}
	recs := fetches.Records()
	if len(recs) != 1 {
		t.Fatalf("got %d records, want 1", len(recs))
	}
	rec := recs[0]

	if string(rec.Key) != "SIM00000000000003" {
		t.Errorf("key = %q, want SIM00000000000003", rec.Key)
	}
	if string(rec.Value) != string(payload) {
		t.Errorf("value bytes were modified: got %x, want %x", rec.Value, payload)
	}
	var gotHeader string
	for _, hd := range rec.Headers {
		if hd.Key == "ingest_ts" {
			gotHeader = string(hd.Value)
		}
	}
	if want := "1700000000000"; gotHeader != want {
		t.Errorf("ingest_ts header = %q, want %q", gotHeader, want)
	}
}

func TestInvoke_ReturnsErrorWhenProduceFails(t *testing.T) {
	// Nothing listens on this address, so every produce attempt fails fast.
	cl, err := kgo.NewClient(
		kgo.SeedBrokers("127.0.0.1:1"),
		kgo.RecordRetries(0),
		kgo.RetryTimeout(0),
	)
	if err != nil {
		t.Fatalf("kgo.NewClient: %v", err)
	}
	defer cl.Close()

	h := &bridgeHandler{cl: cl, topic: "raw-telemetry", log: quietLogger()}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := h.Invoke(ctx, testTelemetry("SIM00000000000004")); err == nil {
		t.Fatal("expected an error when the broker is unreachable")
	}
}
