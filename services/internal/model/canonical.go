package model

import (
	"errors"
	"fmt"
	"strings"
	"time"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
)

const (
	SchemaVersion   = 1
	UnassignedFleet = "UNASSIGNED"
)

// CanonicalEvent is the JSON message on the "canonical-events" topic, persisted to
// OpenSearch and streamed to browsers unchanged.
type CanonicalEvent struct {
	EventID            string  `json:"eventId"`
	SchemaVersion      int     `json:"schemaVersion"`
	VIN                string  `json:"vin"`
	FleetID            string  `json:"fleetId"`
	Lng                float64 `json:"lng"`
	Lat                float64 `json:"lat"`
	Status             string  `json:"status"`
	BatterySOC         float64 `json:"batterySOC"`
	DeviceTimestamp    int64   `json:"deviceTimestamp"`
	IngestTimestamp    int64   `json:"ingestTimestamp"`
	ProcessedTimestamp int64   `json:"processedTimestamp"`
}

func StatusString(s telemetryv1.VehicleStatus) string {
	return strings.TrimPrefix(s.String(), "VEHICLE_STATUS_")
}

// Validate rejects messages that cannot be trusted downstream.
func Validate(m *telemetryv1.VehicleTelemetry, now time.Time) error {
	switch {
	case len(m.GetVin()) != 17:
		return fmt.Errorf("invalid VIN %q", m.GetVin())
	case m.GetLat() < -90 || m.GetLat() > 90 || m.GetLng() < -180 || m.GetLng() > 180:
		return errors.New("coordinates out of range")
	case m.GetBatterySoc() < 0 || m.GetBatterySoc() > 100:
		return errors.New("batterySOC out of range")
	case m.GetDeviceTimestamp() <= 0:
		return errors.New("missing deviceTimestamp")
	case m.GetDeviceTimestamp() > now.Add(5*time.Minute).UnixMilli():
		return errors.New("deviceTimestamp in the future")
	}
	return nil
}

func EventID(vin string, deviceTs int64) string { return fmt.Sprintf("%s-%d", vin, deviceTs) }
