package authz

import (
	"context"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/example/fleet-telemetry/internal/platform"
)

// Syncer projects vehicle->fleet assignments from PostgreSQL (source of truth)
// into Redis, where telemetry-processor reads them on the hot path.
type Syncer struct {
	Store *Store
	Redis *redis.Client
	Log   *slog.Logger
}

func (s *Syncer) SyncOnce(ctx context.Context) error {
	mapping, err := s.Store.VehicleFleets(ctx)
	if err != nil {
		return err
	}
	known, err := s.Redis.SMembers(ctx, platform.FleetIndexKey).Result()
	if err != nil {
		return err
	}
	pipe := s.Redis.TxPipeline()
	for vin, fleet := range mapping {
		pipe.Set(ctx, platform.FleetKey(vin), fleet, 0)
		pipe.SAdd(ctx, platform.FleetIndexKey, vin)
	}
	removed := 0
	for _, vin := range known {
		if _, ok := mapping[vin]; !ok {
			pipe.Del(ctx, platform.FleetKey(vin))
			pipe.SRem(ctx, platform.FleetIndexKey, vin)
			removed++
		}
	}
	if _, err := pipe.Exec(ctx); err != nil {
		return err
	}
	s.Log.Debug("fleet mapping synced", "vehicles", len(mapping), "removed", removed)
	return nil
}

// SetOne pushes a single assignment immediately after an admin change.
func (s *Syncer) SetOne(ctx context.Context, vin, fleet string) error {
	pipe := s.Redis.TxPipeline()
	pipe.Set(ctx, platform.FleetKey(vin), fleet, 0)
	pipe.SAdd(ctx, platform.FleetIndexKey, vin)
	_, err := pipe.Exec(ctx)
	return err
}

func (s *Syncer) Run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := s.SyncOnce(ctx); err != nil {
				s.Log.Error("fleet mapping sync failed", "err", err)
			}
		}
	}
}
