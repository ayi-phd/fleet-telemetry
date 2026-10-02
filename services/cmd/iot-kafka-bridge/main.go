// iot-kafka-bridge is the container-image Lambda AWS IoT Core invokes for every
// message on "fleet/telemetry" (on Floci, the emulator invokes the same image).
// It reads only the VIN and republishes the original protobuf bytes to MSK
// "raw-telemetry", unmodified, keyed by VIN. See PLAN.md Phase 1.
package main

import (
	"context"
	"log/slog"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/twmb/franz-go/pkg/kgo"

	"github.com/example/fleet-telemetry/internal/platform"
)

func main() {
	log := platform.NewLogger("iot-kafka-bridge")
	patchFlociHosts(log)

	producer, closeFn := newProducer(log)
	defer closeFn()

	h := &bridgeHandler{producer: producer, log: log}
	lambda.StartHandler(h)
}

// newProducer picks a RawProducer based on STREAM_RAW (default "msk", today's
// behavior). This binary only runs on Floci after PLAN.md Phase 7 - real AWS routes
// IoT Core directly into the raw stream via a native rule action instead - but it
// still needs to speak either transport, since Floci can be configured for either.
func newProducer(log *slog.Logger) (producer RawProducer, closeFn func()) {
	if platform.Env("STREAM_RAW", "msk") == "kinesis" {
		kin, err := platform.NewKinesis(context.Background(), platform.MustEnv("AWS_REGION"))
		if err != nil {
			log.Error("kinesis client", "err", err)
			os.Exit(1)
		}
		return &kinesisProducer{kin: kin, stream: platform.MustEnv("RAW_STREAM_NAME")}, func() {}
	}

	kc := platform.KafkaConfigFromEnv()
	cl, err := kgo.NewClient(append(kc.Opts(),
		kgo.ProducerBatchCompression(kgo.Lz4Compression()),
	)...)
	if err != nil {
		log.Error("kafka client", "err", err)
		os.Exit(1)
	}
	return &kafkaProducer{cl: cl, topic: platform.Env("RAW_TOPIC", "raw-telemetry")}, cl.Close
}

// patchFlociHosts appends FLOCI_EXTRA_HOSTS's "ip name" lines to /etc/hosts. Floci's
// Lambda execution containers sit outside the k3s cluster, so deploy.sh's node/CoreDNS
// patching never reaches them - yet Kafka's protocol advertises MSK's randomly-suffixed
// container name in metadata responses, so even an IP bootstrap address isn't enough for
// the produce request that follows (confirmed on a live run - PLAN.md Phase 4). Unset
// (and a no-op) on AWS.
func patchFlociHosts(log *slog.Logger) {
	extra := platform.Env("FLOCI_EXTRA_HOSTS", "")
	if extra == "" {
		return
	}
	current, err := os.ReadFile("/etc/hosts")
	if err != nil {
		log.Error("read /etc/hosts", "err", err)
		return
	}
	f, err := os.OpenFile("/etc/hosts", os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		log.Error("open /etc/hosts", "err", err)
		return
	}
	defer f.Close()
	for _, line := range strings.Split(extra, "\n") {
		if line == "" || strings.Contains(string(current), line) {
			continue
		}
		if _, err := f.WriteString(line + "\n"); err != nil {
			log.Error("patch /etc/hosts", "line", line, "err", err)
		}
	}
}
