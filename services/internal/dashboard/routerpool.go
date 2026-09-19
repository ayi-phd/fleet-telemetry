package dashboard

import (
	"context"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
)

var routerStreams = promauto.NewGauge(prometheus.GaugeOpts{
	Name: "dashboard_router_streams", Help: "Active gRPC streams to realtime-router pods.",
})

// RouterPool keeps one Subscribe stream open to every realtime-router pod.
// Router pods each consume a subset of canonical-events partitions, so a dashboard
// pod must be connected to all of them. Pods are discovered via the headless service.
type RouterPool struct {
	Host         string // headless service DNS name
	Port         string
	SubscriberID string
	Bus          *InterestBus
	Broker       *Broker
	Log          *slog.Logger

	mu      sync.Mutex
	streams map[string]context.CancelFunc
}

func (p *RouterPool) Run(ctx context.Context) {
	p.streams = map[string]context.CancelFunc{}
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		p.reconcile(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (p *RouterPool) reconcile(ctx context.Context) {
	lookupCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	ips, err := net.DefaultResolver.LookupHost(lookupCtx, p.Host)
	cancel()
	if err != nil {
		p.Log.Warn("router discovery failed", "host", p.Host, "err", err)
		return // keep existing streams
	}
	want := map[string]struct{}{}
	for _, ip := range ips {
		want[net.JoinHostPort(ip, p.Port)] = struct{}{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for addr, stop := range p.streams {
		if _, ok := want[addr]; !ok {
			stop()
			delete(p.streams, addr)
		}
	}
	for addr := range want {
		if _, ok := p.streams[addr]; !ok {
			sctx, stop := context.WithCancel(ctx)
			p.streams[addr] = stop
			go p.maintain(sctx, addr)
		}
	}
}

func (p *RouterPool) maintain(ctx context.Context, addr string) {
	backoff := 500 * time.Millisecond
	for ctx.Err() == nil {
		start := time.Now()
		err := p.stream(ctx, addr)
		if ctx.Err() != nil {
			return
		}
		if time.Since(start) > time.Minute {
			backoff = 500 * time.Millisecond
		}
		p.Log.Warn("router stream ended; reconnecting", "router", addr, "err", err, "in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff *= 2; backoff > 10*time.Second {
			backoff = 10 * time.Second
		}
	}
}

func (p *RouterPool) stream(ctx context.Context, addr string) error {
	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{Time: 20 * time.Second, Timeout: 10 * time.Second, PermitWithoutStream: true}),
	)
	if err != nil {
		return err
	}
	defer conn.Close()

	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := routerv1.NewRealtimeRouterClient(conn).Subscribe(sctx)
	if err != nil {
		return err
	}
	changed, unwatch := p.Bus.Watch()
	defer unwatch()

	if err := stream.Send(&routerv1.SubscribeRequest{Msg: &routerv1.SubscribeRequest_Hello{
		Hello: &routerv1.Hello{SubscriberId: p.SubscriberID}}}); err != nil {
		return err
	}
	sendInterest := func() error {
		return stream.Send(&routerv1.SubscribeRequest{Msg: &routerv1.SubscribeRequest_Interest{Interest: p.Bus.Current()}})
	}
	if err := sendInterest(); err != nil {
		return err
	}

	routerStreams.Inc()
	defer routerStreams.Dec()
	p.Log.Info("connected to router", "router", addr)

	recvErr := make(chan error, 1)
	go func() {
		for {
			ev, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			p.Broker.Dispatch(ev)
		}
	}()

	for {
		select {
		case <-ctx.Done():
			_ = stream.CloseSend()
			return nil
		case err := <-recvErr:
			return err
		case <-changed:
			if err := sendInterest(); err != nil {
				return err
			}
		}
	}
}
