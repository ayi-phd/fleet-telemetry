package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
	"github.com/example/fleet-telemetry/internal/authz"
	"github.com/example/fleet-telemetry/internal/platform"
)

func main() {
	log := platform.NewLogger("rbac-authz")
	ctx, stop := platform.SignalContext()
	defer stop()

	ops := &platform.Health{}
	go platform.ServeOps(ctx, platform.Env("OPS_ADDR", ":8081"), ops)

	pool, err := pgxpool.New(ctx, platform.MustEnv("POSTGRES_DSN"))
	if err != nil {
		log.Error("postgres config", "err", err)
		os.Exit(1)
	}
	defer pool.Close()
	store := &authz.Store{DB: pool}
	if err := platform.Retry(ctx, "postgres migrate", store.Migrate); err != nil {
		return
	}
	if platform.EnvBool("SEED_DEMO_DATA", false) {
		if err := store.Seed(ctx, platform.EnvInt("DEMO_VEHICLE_COUNT", 12), platform.MustEnv("DEMO_PASSWORD")); err != nil {
			log.Error("seed demo data", "err", err)
			os.Exit(1)
		}
		log.Info("demo data seeded")
	}

	rdb := platform.NewRedis()
	defer rdb.Close()
	syncer := &authz.Syncer{Store: store, Redis: rdb, Log: log}
	if err := platform.Retry(ctx, "initial fleet sync", syncer.SyncOnce); err != nil {
		return
	}
	go syncer.Run(ctx, platform.EnvDuration("SYNC_INTERVAL", 30*time.Second))

	lis, err := net.Listen("tcp", platform.Env("GRPC_ADDR", ":9090"))
	if err != nil {
		log.Error("listen", "err", err)
		os.Exit(1)
	}
	gs := grpc.NewServer()
	authzv1.RegisterAuthzServiceServer(gs, &authz.GRPC{Store: store})
	healthpb.RegisterHealthServer(gs, health.NewServer())
	go func() {
		if err := gs.Serve(lis); err != nil {
			log.Error("grpc server", "err", err)
		}
	}()

	h := &authz.HTTP{
		Store:        store,
		Syncer:       syncer,
		JWTKey:       []byte(platform.MustEnv("JWT_SIGNING_KEY")),
		TokenTTL:     platform.EnvDuration("TOKEN_TTL", 12*time.Hour),
		SecureCookie: platform.EnvBool("COOKIE_SECURE", false),
		Log:          log,
	}
	srv := &http.Server{Addr: platform.Env("HTTP_ADDR", ":8080"), Handler: h.Routes(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		ops.SetReady(false)
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
		gs.GracefulStop()
	}()

	ops.SetReady(true)
	log.Info("rbac-authz started")
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http server", "err", err)
		os.Exit(1)
	}
}
