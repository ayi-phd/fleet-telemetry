package platform

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kerr"
	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/sasl/scram"
)

// KafkaConfig targets MSK with TLS + SASL/SCRAM-SHA-512 (port 9096).
type KafkaConfig struct {
	Brokers  []string
	Username string
	Password string
	TLS      bool
}

func KafkaConfigFromEnv() KafkaConfig {
	brokers := EnvList("KAFKA_BROKERS")
	if len(brokers) == 0 {
		MustEnv("KAFKA_BROKERS")
	}
	return KafkaConfig{
		Brokers:  brokers,
		Username: Env("KAFKA_USERNAME", ""),
		Password: Env("KAFKA_PASSWORD", ""),
		TLS:      EnvBool("KAFKA_TLS", true),
	}
}

func (c KafkaConfig) Opts() []kgo.Opt {
	opts := []kgo.Opt{kgo.SeedBrokers(c.Brokers...)}
	if c.TLS {
		opts = append(opts, kgo.DialTLSConfig(&tls.Config{MinVersion: tls.VersionTLS12}))
	}
	if c.Username != "" {
		opts = append(opts, kgo.SASL(scram.Auth{User: c.Username, Pass: c.Password}.AsSha512Mechanism()))
	}
	return opts
}

// EnsureTopics creates topics if they do not exist, with explicit retention and
// min.insync.replicas set per topic rather than relying on broker-wide defaults or
// topic auto-creation (there is no custom MSK configuration; see terraform/infra/msk.tf).
// Existing topics are left untouched.
func EnsureTopics(ctx context.Context, cl *kgo.Client, partitions int32, replication int16, retention time.Duration, minInsyncReplicas int, topics ...string) error {
	retentionMs := strconv.FormatInt(retention.Milliseconds(), 10)
	minISR := strconv.Itoa(minInsyncReplicas)
	configs := map[string]*string{
		"retention.ms":        &retentionMs,
		"min.insync.replicas": &minISR,
	}

	adm := kadm.NewClient(cl)
	resp, err := adm.CreateTopics(ctx, partitions, replication, configs, topics...)
	if err != nil {
		return err
	}
	for name, r := range resp {
		if r.Err != nil && !errors.Is(r.Err, kerr.TopicAlreadyExists) {
			return fmt.Errorf("create topic %s: %w", name, r.Err)
		}
	}
	return nil
}
