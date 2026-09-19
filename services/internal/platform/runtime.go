package platform

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// NewLogger configures JSON structured logging and sets it as the default logger.
func NewLogger(service string) *slog.Logger {
	level := slog.LevelInfo
	if Env("LOG_LEVEL", "info") == "debug" {
		level = slog.LevelDebug
	}
	l := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})).
		With("service", service, "pod", os.Getenv("POD_NAME"))
	slog.SetDefault(l)
	return l
}

// SignalContext is cancelled on SIGINT/SIGTERM (Kubernetes pod termination).
func SignalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
}

// Health backs the Kubernetes liveness/readiness probes.
type Health struct{ ready atomic.Bool }

func (h *Health) SetReady(v bool) { h.ready.Store(v) }

// ServeOps exposes /healthz, /readyz and /metrics until ctx is cancelled.
func ServeOps(ctx context.Context, addr string, h *Health) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, _ *http.Request) {
		if h.ready.Load() {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	mux.Handle("/metrics", promhttp.Handler())
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("ops server failed", "err", err)
	}
}

// Retry calls fn with capped exponential backoff until it succeeds or ctx is done.
func Retry(ctx context.Context, what string, fn func(context.Context) error) error {
	delay := 500 * time.Millisecond
	for attempt := 1; ; attempt++ {
		err := fn(ctx)
		if err == nil {
			return nil
		}
		slog.Warn("operation failed, retrying", "op", what, "attempt", attempt, "err", err, "delay", delay)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		if delay *= 2; delay > 15*time.Second {
			delay = 15 * time.Second
		}
	}
}
