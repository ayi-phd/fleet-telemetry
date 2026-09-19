package main

import (
	"net"
	"os"
	"time"

	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/keepalive"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
	"github.com/example/fleet-telemetry/internal/platform"
	"github.com/example/fleet-telemetry/internal/router"
)

func main() {
	log := platform.NewLogger("realtime-router")
	ctx, stop := platform.SignalContext()
	defer stop()

	ops := &platform.Health{}
	go platform.ServeOps(ctx, platform.Env("OPS_ADDR", ":8081"), ops)

	topic := platform.Env("CANONICAL_TOPIC", "canonical-events")
	kc := platform.KafkaConfigFromEnv()
	hub := router.NewHub()

	osClient, err := platform.NewOpenSearch(ctx, platform.MustEnv("OPENSEARCH_ENDPOINT"), platform.MustEnv("AWS_REGION"))
	if err != nil {
		log.Error("opensearch client", "err", err)
		os.Exit(1)
	}
	persister := &router.Persister{OS: osClient, IndexPrefix: platform.Env("INDEX_PREFIX", "telemetry"), Log: log}
	if err := platform.Retry(ctx, "opensearch index template", persister.EnsureTemplate); err != nil {
		return
	}

	lis, err := net.Listen("tcp", platform.Env("GRPC_ADDR", ":9090"))
	if err != nil {
		log.Error("listen", "err", err)
		os.Exit(1)
	}
	srv := grpc.NewServer(
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{MinTime: 10 * time.Second, PermitWithoutStream: true}),
		grpc.KeepaliveParams(keepalive.ServerParameters{Time: 30 * time.Second, Timeout: 10 * time.Second}),
	)
	routerv1.RegisterRealtimeRouterServer(srv, &router.Server{
		Hub: hub, Buffer: platform.EnvInt("SUBSCRIBER_BUFFER", 4096), Log: log,
	})
	hs := health.NewServer()
	healthpb.RegisterHealthServer(srv, hs)

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error { return srv.Serve(lis) })
	g.Go(func() error {
		return router.RunPush(gctx, kc, topic, platform.Env("PUSH_GROUP", "realtime-router-push"),
			platform.EnvDuration("PUSH_MAX_AGE", 30*time.Second), hub, log)
	})
	g.Go(func() error {
		return persister.Run(gctx, kc, topic, platform.Env("PERSIST_GROUP", "realtime-router-persist"))
	})
	g.Go(func() error {
		<-gctx.Done()
		ops.SetReady(false)
		hs.Shutdown()
		done := make(chan struct{})
		go func() { srv.GracefulStop(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			srv.Stop() // streams are long-lived; dashboard-api reconnects to remaining pods
		}
		return nil
	})

	ops.SetReady(true)
	log.Info("realtime-router started", "topic", topic)
	if err := g.Wait(); err != nil && ctx.Err() == nil {
		log.Error("realtime-router failed", "err", err)
		os.Exit(1)
	}
	log.Info("realtime-router stopped")
}
