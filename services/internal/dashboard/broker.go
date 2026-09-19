package dashboard

import (
	"sort"
	"sync"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
)

var (
	sseClients = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "dashboard_sse_clients", Help: "Connected browser SSE streams on this pod.",
	})
	sseDropped = promauto.NewCounter(prometheus.CounterOpts{
		Name: "dashboard_sse_dropped_total", Help: "Events dropped for slow browsers.",
	})
)

// Scope is one user's authorization, from rbac-authz.
type Scope struct {
	All    bool
	Fleets map[string]struct{}
	VINs   map[string]struct{}
}

func ScopeFromProto(s *authzv1.UserScope) *Scope {
	out := &Scope{All: s.GetAllFleets(), Fleets: map[string]struct{}{}, VINs: map[string]struct{}{}}
	for _, f := range s.GetFleetIds() {
		out.Fleets[f] = struct{}{}
	}
	for _, v := range s.GetVins() {
		out.VINs[v] = struct{}{}
	}
	return out
}

func (s *Scope) Allows(fleetID, vin string) bool {
	if s.All {
		return true
	}
	if _, ok := s.Fleets[fleetID]; ok {
		return true
	}
	_, ok := s.VINs[vin]
	return ok
}

// Client is one browser SSE connection.
type Client struct {
	UserID string
	Out    chan []byte
	scope  atomic.Pointer[Scope]
}

func NewClient(userID string, scope *Scope) *Client {
	c := &Client{UserID: userID, Out: make(chan []byte, 512)}
	c.scope.Store(scope)
	return c
}

// Broker holds this pod's SSE clients, filters events per user (second, authoritative
// filter) and publishes the union of all scopes to the router pool (first filter).
type Broker struct {
	mu      sync.RWMutex
	clients map[*Client]struct{}
	bus     *InterestBus
}

func NewBroker(bus *InterestBus) *Broker {
	return &Broker{clients: map[*Client]struct{}{}, bus: bus}
}

func (b *Broker) Register(c *Client) {
	b.mu.Lock()
	b.clients[c] = struct{}{}
	b.mu.Unlock()
	sseClients.Inc()
	b.recompute()
}

func (b *Broker) Unregister(c *Client) {
	b.mu.Lock()
	delete(b.clients, c)
	b.mu.Unlock()
	sseClients.Dec()
	b.recompute()
}

func (b *Broker) Dispatch(ev *routerv1.TelemetryEvent) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	for c := range b.clients {
		if !c.scope.Load().Allows(ev.GetFleetId(), ev.GetVin()) {
			continue
		}
		select {
		case c.Out <- ev.GetCanonicalJson():
		default:
			sseDropped.Inc()
		}
	}
}

// UserIDs returns the distinct users connected to this pod.
func (b *Broker) UserIDs() []string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	set := map[string]struct{}{}
	for c := range b.clients {
		set[c.UserID] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for u := range set {
		out = append(out, u)
	}
	return out
}

// UpdateScope applies a refreshed scope to all of a user's connections.
func (b *Broker) UpdateScope(userID string, s *Scope) {
	b.mu.RLock()
	for c := range b.clients {
		if c.UserID == userID {
			c.scope.Store(s)
		}
	}
	b.mu.RUnlock()
	b.recompute()
}

func (b *Broker) recompute() {
	b.mu.RLock()
	all := false
	fleets, vins := map[string]struct{}{}, map[string]struct{}{}
	for c := range b.clients {
		s := c.scope.Load()
		if s.All {
			all = true
		}
		for f := range s.Fleets {
			fleets[f] = struct{}{}
		}
		for v := range s.VINs {
			vins[v] = struct{}{}
		}
	}
	b.mu.RUnlock()
	if all { // admins see everything; no need to enumerate
		fleets, vins = nil, nil
	}
	b.bus.Set(all, sortedKeys(fleets), sortedKeys(vins))
}

func sortedKeys(m map[string]struct{}) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
