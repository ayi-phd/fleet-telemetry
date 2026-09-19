package main

import (
	"errors"
	"net/http"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
	"github.com/example/fleet-telemetry/internal/dashboard"
	"github.com/example/fleet-telemetry/internal/platform"
)

func main() {
	log := platform.NewLogger("dashboard-api")
	ctx, stop := platform.SignalContext()
	defer stop()

	ops := &platform.Health{}
	go platform.ServeOps(ctx, platform.Env("OPS_ADDR", ":8081"), ops)

	conn, err := grpc.NewClient(platform.Env("AUTHZ_ADDR", "dns:///rbac-authz:9090"),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultServiceConfig(`{"loadBalancingConfig":[{"round_robin":{}}]}`))
	if err != nil {
		log.Error("authz client", "err", err)
		os.Exit(1)
	}
	defer conn.Close()

	osClient, err := platform.NewOpenSearch(ctx, platform.MustEnv("OPENSEARCH_ENDPOINT"), platform.MustEnv("AWS_REGION"))
	if err != nil {
		log.Error("opensearch client", "err", err)
		os.Exit(1)
	}

	bus := dashboard.NewInterestBus()
	broker := dashboard.NewBroker(bus)
	pool := &dashboard.RouterPool{
		Host:         platform.Env("ROUTER_HEADLESS_HOST", "realtime-router-headless"),
		Port:         platform.Env("ROUTER_PORT", "9090"),
		SubscriberID: platform.Env("POD_NAME", "dashboard-api-local"),
		Bus:          bus,
		Broker:       broker,
		Log:          log,
	}
	go pool.Run(ctx)

	api := &dashboard.API{
		JWTKey:       []byte(platform.MustEnv("JWT_SIGNING_KEY")),
		Authz:        authzv1.NewAuthzServiceClient(conn),
		Broker:       broker,
		OS:           osClient,
		IndexPattern: platform.Env("INDEX_PREFIX", "telemetry") + "-*",
		Heartbeat:    platform.EnvDuration("SSE_HEARTBEAT", 15*time.Second),
		ScopeRefresh: platform.EnvDuration("SCOPE_REFRESH", time.Minute),
		Log:          log,
	}
	go api.RefreshScopes(ctx)

	// WriteTimeout stays 0: SSE responses are long-lived.
	srv := &http.Server{Addr: platform.Env("HTTP_ADDR", ":8080"), Handler: api.Routes(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		ops.SetReady(false)
		// Closing listeners and connections ends SSE streams; browsers reconnect to another pod.
		_ = srv.Close()
	}()
	ops.SetReady(true)
	log.Info("dashboard-api started", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http server", "err", err)
		os.Exit(1)
	}
}
