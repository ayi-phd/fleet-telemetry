package router

import (
	"sync"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
)

var (
	subscribersGauge = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "realtime_router_subscribers", Help: "Connected dashboard-api streams.",
	})
	deliveredTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "realtime_router_events_delivered_total", Help: "Events sent to dashboard-api streams.",
	})
	droppedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "realtime_router_events_dropped_total", Help: "Events dropped because a stream was too slow.",
	})
	unroutedTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "realtime_router_events_unrouted_total", Help: "Events no subscriber was interested in.",
	})
)

// Interest is what a dashboard-api pod currently needs: the union of its users' scopes.
type Interest struct {
	All    bool
	Fleets map[string]struct{}
	VINs   map[string]struct{}
}

func InterestFromProto(u *routerv1.InterestUpdate) *Interest {
	in := &Interest{All: u.GetAll(), Fleets: map[string]struct{}{}, VINs: map[string]struct{}{}}
	for _, f := range u.GetFleetIds() {
		in.Fleets[f] = struct{}{}
	}
	for _, v := range u.GetVins() {
		in.VINs[v] = struct{}{}
	}
	return in
}

func (i *Interest) Matches(fleetID, vin string) bool {
	if i.All {
		return true
	}
	if _, ok := i.Fleets[fleetID]; ok {
		return true
	}
	_, ok := i.VINs[vin]
	return ok
}

type Subscriber struct {
	ID       string
	Out      chan *routerv1.TelemetryEvent
	interest atomic.Pointer[Interest]
}

func NewSubscriber(id string, buffer int) *Subscriber {
	s := &Subscriber{ID: id, Out: make(chan *routerv1.TelemetryEvent, buffer)}
	s.interest.Store(&Interest{}) // no interest until the first InterestUpdate arrives
	return s
}

func (s *Subscriber) SetInterest(i *Interest) { s.interest.Store(i) }

// Hub fans events out to subscribers whose interest matches.
// The subscriber count is the number of dashboard-api pods (tens), so a linear scan
// with O(1) map lookups per subscriber is cheaper than maintaining an inverted index.
type Hub struct {
	mu   sync.RWMutex
	subs map[*Subscriber]struct{}
}

func NewHub() *Hub { return &Hub{subs: map[*Subscriber]struct{}{}} }

func (h *Hub) Add(s *Subscriber) {
	h.mu.Lock()
	h.subs[s] = struct{}{}
	n := len(h.subs)
	h.mu.Unlock()
	subscribersGauge.Set(float64(n))
}

func (h *Hub) Remove(s *Subscriber) {
	h.mu.Lock()
	delete(h.subs, s)
	n := len(h.subs)
	h.mu.Unlock()
	subscribersGauge.Set(float64(n))
}

func (h *Hub) Dispatch(ev *routerv1.TelemetryEvent) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	routed := false
	for s := range h.subs {
		if !s.interest.Load().Matches(ev.GetFleetId(), ev.GetVin()) {
			continue
		}
		routed = true
		select {
		case s.Out <- ev:
			deliveredTotal.Inc()
		default:
			droppedTotal.Inc() // live telemetry: newer positions supersede dropped ones
		}
	}
	if !routed {
		unroutedTotal.Inc()
	}
}
