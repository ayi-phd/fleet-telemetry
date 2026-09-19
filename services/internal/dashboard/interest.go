package dashboard

import (
	"slices"
	"sync"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
)

// InterestBus holds this pod's current routing interest and wakes every router
// stream when it changes so each can send an InterestUpdate.
type InterestBus struct {
	mu       sync.Mutex
	cur      *routerv1.InterestUpdate
	watchers map[chan struct{}]struct{}
}

func NewInterestBus() *InterestBus {
	return &InterestBus{cur: &routerv1.InterestUpdate{}, watchers: map[chan struct{}]struct{}{}}
}

func (b *InterestBus) Set(all bool, fleets, vins []string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cur.GetAll() == all && slices.Equal(b.cur.GetFleetIds(), fleets) && slices.Equal(b.cur.GetVins(), vins) {
		return
	}
	b.cur = &routerv1.InterestUpdate{All: all, FleetIds: fleets, Vins: vins, Version: b.cur.GetVersion() + 1}
	for ch := range b.watchers {
		select {
		case ch <- struct{}{}:
		default: // already signalled; the watcher will read the latest value
		}
	}
}

func (b *InterestBus) Current() *routerv1.InterestUpdate {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.cur
}

func (b *InterestBus) Watch() (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	b.mu.Lock()
	b.watchers[ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.watchers, ch)
		b.mu.Unlock()
	}
}
