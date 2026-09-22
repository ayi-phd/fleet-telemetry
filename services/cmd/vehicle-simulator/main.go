// vehicle-simulator publishes protobuf telemetry for the demo IoT things created by
// Terraform. Each vehicle is its own MQTT connection authenticated with its own X.509
// certificate; client id == thing name == VIN, as the IoT policy requires.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"google.golang.org/protobuf/proto"

	telemetryv1 "github.com/example/fleet-telemetry/gen/telemetry/v1"
	"github.com/example/fleet-telemetry/internal/platform"
)

const topic = "fleet/telemetry"

func main() {
	log := platform.NewLogger("vehicle-simulator")
	ctx, stop := platform.SignalContext()
	defer stop()
	ops := &platform.Health{}
	go platform.ServeOps(ctx, platform.Env("OPS_ADDR", ":8081"), ops)

	endpoint := platform.MustEnv("IOT_ENDPOINT")
	certDir := platform.Env("CERT_DIR", "/certs")
	interval := platform.EnvDuration("PUBLISH_INTERVAL", 2*time.Second)
	dupRate := platform.EnvFloat("DUPLICATE_RATE", 0.03)
	centerLat := platform.EnvFloat("CENTER_LAT", 37.7749)
	centerLng := platform.EnvFloat("CENTER_LNG", -122.4194)
	// IOT_TLS mirrors KAFKA_TLS/REDIS_TLS elsewhere: true on AWS (real IoT Core requires
	// mutual TLS on 8883). false only on Floci, whose 8883 listener never completes a TLS
	// handshake regardless of client certificate (confirmed directly against the raw
	// socket - PLAN.md Phase 4), unlike its plaintext MQTT broker on 1883, which works.
	tlsEnabled := platform.EnvBool("IOT_TLS", true)
	// IOT_WIRE_JSON: Floci only. Its IoT rules engine forces every MQTT payload through
	// UTF-8 decoding before any rule SQL runs, silently replacing invalid byte sequences
	// with U+FFFD - confirmed by inspecting the exact bytes the Lambda received, which
	// were the original protobuf with every non-UTF8 byte corrupted this way. No rule SQL
	// variant works around it, since the corruption happens before SQL evaluation (PLAN.md
	// Phase 4). Publishing a UTF-8-safe JSON envelope instead of raw protobuf bytes avoids
	// the corruption; iot-kafka-bridge already unwraps exactly this envelope
	// (decodePayload's base64 "payload" field) and forwards the original, unmodified
	// protobuf bytes to Kafka, so telemetry-processor sees identical records on both
	// targets. AWS keeps the real wire format: protobuf bytes, no envelope.
	wireJSON := platform.EnvBool("IOT_WIRE_JSON", false)

	// IOT_CA_FILE is the CA that signs the broker's TLS certificate: Amazon Root CA 1 on
	// AWS. Not in the system trust store, so without it the connection fails closed
	// rather than silently trusting nothing extra. Unused when IOT_TLS is false.
	var caPool *x509.CertPool
	if tlsEnabled {
		caFile := platform.Env("IOT_CA_FILE", "")
		var err error
		caPool, err = loadCAPool(caFile)
		if err != nil {
			log.Error("load IoT CA file", "file", caFile, "err", err)
			os.Exit(1)
		}
	}

	vins, err := discoverVINs(certDir)
	if err != nil || len(vins) == 0 {
		log.Error("no vehicle certificates found", "dir", certDir, "err", err)
		os.Exit(1)
	}
	log.Info("starting simulation", "vehicles", len(vins), "interval", interval)

	var wg sync.WaitGroup
	for i, vin := range vins {
		wg.Add(1)
		go func(i int, vin string) {
			defer wg.Done()
			// Stagger connections to stay well inside IoT Core connect-rate limits.
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Duration(i) * 200 * time.Millisecond):
			}
			v := newVehicle(vin, centerLat, centerLng)
			if err := v.run(ctx, endpoint, certDir, interval, dupRate, tlsEnabled, wireJSON, caPool); err != nil {
				log.Error("vehicle stopped", "vin", vin, "err", err)
			}
		}(i, vin)
	}
	ops.SetReady(true)
	wg.Wait()
}

func discoverVINs(dir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.cert.pem"))
	if err != nil {
		return nil, err
	}
	var vins []string
	for _, m := range matches {
		vins = append(vins, strings.TrimSuffix(filepath.Base(m), ".cert.pem"))
	}
	sort.Strings(vins)
	return vins, nil
}

// loadCAPool reads a PEM CA bundle for trusting the IoT broker's TLS certificate.
// An empty path falls back to nil, meaning "trust the system's root store" - today's
// behavior, kept for anyone running the simulator without IOT_CA_FILE configured.
func loadCAPool(path string) (*x509.CertPool, error) {
	if path == "" {
		return nil, nil
	}
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("no certificates found in %s", path)
	}
	return pool, nil
}

type vehicle struct {
	vin      string
	lat, lng float64
	heading  float64
	soc      float64
	status   telemetryv1.VehicleStatus
	rng      *rand.Rand
}

func newVehicle(vin string, lat, lng float64) *vehicle {
	seed := uint64(0)
	for _, c := range vin {
		seed = seed*31 + uint64(c)
	}
	r := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	return &vehicle{
		vin:     vin,
		lat:     lat + (r.Float64()-0.5)*0.12,
		lng:     lng + (r.Float64()-0.5)*0.12,
		heading: r.Float64() * 2 * math.Pi,
		soc:     40 + r.Float64()*60,
		status:  telemetryv1.VehicleStatus_VEHICLE_STATUS_DRIVING,
		rng:     r,
	}
}

func (v *vehicle) step(dt time.Duration) {
	secs := dt.Seconds()
	switch v.status {
	case telemetryv1.VehicleStatus_VEHICLE_STATUS_DRIVING:
		v.heading += (v.rng.Float64() - 0.5) * 0.6
		speed := 0.00012 * secs // ~13 m/s
		v.lat += math.Cos(v.heading) * speed
		v.lng += math.Sin(v.heading) * speed / math.Cos(v.lat*math.Pi/180)
		v.soc -= 0.03 * secs
		switch {
		case v.soc < 15:
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_CHARGING
		case v.rng.Float64() < 0.01:
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_PARKED
		case v.rng.Float64() < 0.005:
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_IDLE
		case v.rng.Float64() < 0.0008:
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_FAULT
		}
	case telemetryv1.VehicleStatus_VEHICLE_STATUS_CHARGING:
		v.soc += 0.4 * secs
		if v.soc >= 95 {
			v.soc = 95
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_DRIVING
		}
	default: // parked, idle, fault
		v.soc -= 0.001 * secs
		if v.rng.Float64() < 0.03 {
			v.status = telemetryv1.VehicleStatus_VEHICLE_STATUS_DRIVING
		}
	}
	v.soc = math.Max(0, math.Min(100, v.soc))
}

func (v *vehicle) run(ctx context.Context, endpoint, certDir string, interval time.Duration, dupRate float64, tlsEnabled, wireJSON bool, caPool *x509.CertPool) error {
	opts := mqtt.NewClientOptions().
		SetClientID(v.vin).
		SetKeepAlive(30 * time.Second).
		SetCleanSession(true).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(5 * time.Second)
	if tlsEnabled {
		cert, err := tls.LoadX509KeyPair(filepath.Join(certDir, v.vin+".cert.pem"), filepath.Join(certDir, v.vin+".key.pem"))
		if err != nil {
			return err
		}
		opts.AddBroker("tls://" + endpoint + ":8883").
			SetTLSConfig(&tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: caPool, MinVersion: tls.VersionTLS12})
	} else {
		opts.AddBroker("tcp://" + endpoint + ":1883")
	}
	client := mqtt.NewClient(opts)
	if tok := client.Connect(); tok.Wait() && tok.Error() != nil {
		return tok.Error()
	}
	slog.Info("connected to IoT broker", "vin", v.vin, "tls", tlsEnabled)
	defer client.Disconnect(250)

	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
		v.step(interval)
		payload, err := proto.Marshal(&telemetryv1.VehicleTelemetry{
			Vin:             v.vin,
			Lat:             v.lat,
			Lng:             v.lng,
			Status:          v.status,
			BatterySoc:      float32(v.soc),
			DeviceTimestamp: time.Now().UnixMilli(),
		})
		if err != nil {
			return err
		}
		if wireJSON {
			payload, err = json.Marshal(wireEnvelope{Payload: base64.StdEncoding.EncodeToString(payload)})
			if err != nil {
				return err
			}
		}
		if !client.IsConnectionOpen() {
			continue
		}
		publish(v.vin, client, payload)
		if v.rng.Float64() < dupRate { // exercise the deduplication path
			publish(v.vin, client, payload)
		}
	}
}

// wireEnvelope matches iot-kafka-bridge's decodePayload: a JSON object carrying the
// original protobuf bytes, base64-encoded, under "payload".
type wireEnvelope struct {
	Payload string `json:"payload"`
}

func publish(vin string, client mqtt.Client, payload []byte) {
	tok := client.Publish(topic, 1, false, payload)
	if !tok.WaitTimeout(5*time.Second) || tok.Error() != nil {
		slog.Warn("publish did not confirm", "vin", vin, "err", tok.Error())
	}
}
