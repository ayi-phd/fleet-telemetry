package platform

import (
	"crypto/tls"
	"time"

	"github.com/redis/go-redis/v9"
)

// NewRedis connects to the ElastiCache primary endpoint (TLS + AUTH token).
func NewRedis() *redis.Client {
	opts := &redis.Options{
		Addr:         MustEnv("REDIS_ADDR"),
		Password:     Env("REDIS_PASSWORD", ""),
		PoolSize:     EnvInt("REDIS_POOL_SIZE", 32),
		DialTimeout:  5 * time.Second,
		ReadTimeout:  2 * time.Second,
		WriteTimeout: 2 * time.Second,
	}
	if EnvBool("REDIS_TLS", true) {
		opts.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	return redis.NewClient(opts)
}

// Key conventions shared by rbac-authz (writer) and telemetry-processor (reader).
func FleetKey(vin string) string           { return "fleet:vin:" + vin }
func DedupKey(vin string, ts int64) string { return "dedup:" + vin + ":" + itoa(ts) }

const FleetIndexKey = "fleet:vins"

func itoa(v int64) string {
	var buf [20]byte
	i := len(buf)
	neg := v < 0
	if neg {
		v = -v
	}
	for {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
		if v == 0 {
			break
		}
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
