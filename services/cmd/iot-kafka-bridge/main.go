// iot-kafka-bridge is the container-image Lambda AWS IoT Core invokes for every
// message on "fleet/telemetry" (on Floci, the emulator invokes the same image).
// It reads only the VIN and republishes the original protobuf bytes to MSK
// "raw-telemetry", unmodified, keyed by VIN. See PLAN.md Phase 1.
package main

import (
	"os"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/example/fleet-telemetry/internal/platform"
)

func main() {
	log := platform.NewLogger("iot-kafka-bridge")

	kc := platform.KafkaConfigFromEnv()
	cl, err := kgo.NewClient(append(kc.Opts(),
		kgo.ProducerBatchCompression(kgo.Lz4Compression()),
	)...)
	if err != nil {
		log.Error("kafka client", "err", err)
		os.Exit(1)
	}
	defer cl.Close()

	h := &bridgeHandler{cl: cl, topic: platform.Env("RAW_TOPIC", "raw-telemetry"), log: log}
	lambda.StartHandler(h)
}
