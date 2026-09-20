// iot-kafka-bridge is the container-image Lambda AWS IoT Core invokes for every
// message on "fleet/telemetry" (on Floci, the emulator invokes the same image).
// It reads only the VIN and republishes the original protobuf bytes to MSK
// "raw-telemetry", unmodified, keyed by VIN. See PLAN.md Phase 1.
package main

import (
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
