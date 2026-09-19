package dashboard

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
	"github.com/example/fleet-telemetry/internal/platform"
)

type API struct {
	JWTKey        []byte
	Authz         authzv1.AuthzServiceClient
	Broker        *Broker
	OS            *platform.OpenSearch
	IndexPattern  string
	Heartbeat     time.Duration
	ScopeRefresh  time.Duration
	Log           *slog.Logger
}


func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /api/me", a.auth(a.me))
	mux.Handle("GET /api/stream", a.auth(a.stream))
	mux.Handle("GET /api/vehicles/latest", a.auth(a.latest))
	return mux
}

func (a *API) auth(next func(http.ResponseWriter, *http.Request, *platform.Claims)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims, err := platform.ParseToken(a.JWTKey, platform.TokenFromRequest(r))
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Sign in to view fleet data."})
			return
		}
		next(w, r, claims)
	})
}

func (a *API) scope(ctx context.Context, userID string) (*authzv1.UserScope, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return a.Authz.GetUserScope(ctx, &authzv1.GetUserScopeRequest{UserId: userID})
}

func (a *API) me(w http.ResponseWriter, r *http.Request, c *platform.Claims) {
	s, err := a.scope(r.Context(), c.Subject)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "Permissions service unavailable."})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"userId": c.Subject, "name": c.Name, "role": c.Role,
		"scope": map[string]any{"all": s.GetAllFleets(), "fleetIds": nonNil(s.GetFleetIds()), "vins": nonNil(s.GetVins())},
	})
}

// stream is the SSE endpoint. Heartbeat comments keep proxies and load balancers from
// closing idle connections; the browser's EventSource reconnects automatically.
func (a *API) stream(w http.ResponseWriter, r *http.Request, c *platform.Claims) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	us, err := a.scope(r.Context(), c.Subject)
	if err != nil {
		http.Error(w, "permissions service unavailable", http.StatusBadGateway)
		return
	}
	client := NewClient(c.Subject, ScopeFromProto(us))
	a.Broker.Register(client)
	defer a.Broker.Unregister(client)

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache, no-transform")
	h.Set("Connection", "keep-alive")
	h.Set("X-Accel-Buffering", "no")
	fmt.Fprintf(w, "retry: 3000\n\nevent: ready\ndata: {\"userId\":%q}\n\n", c.Subject)
	flusher.Flush()

	hb := time.NewTicker(a.Heartbeat)
	defer hb.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-hb.C:
			if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case msg := <-client.Out:
			fmt.Fprintf(w, "event: telemetry\ndata: %s\n\n", msg)
			// Drain whatever else is queued before flushing to batch writes under load.
			for n := 0; n < 64; n++ {
				select {
				case more := <-client.Out:
					fmt.Fprintf(w, "event: telemetry\ndata: %s\n\n", more)
					continue
				default:
				}
				break
			}
			flusher.Flush()
		}
	}
}

// latest returns the most recent position of every vehicle the user may see (last 24h),
// so the dashboard is populated before the first live event arrives.
func (a *API) latest(w http.ResponseWriter, r *http.Request, c *platform.Claims) {
	us, err := a.scope(r.Context(), c.Subject)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "Permissions service unavailable."})
		return
	}
	filters := []any{map[string]any{"range": map[string]any{"deviceTimestamp": map[string]any{"gte": "now-24h"}}}}
	if !us.GetAllFleets() {
		var should []any
		if len(us.GetFleetIds()) > 0 {
			should = append(should, map[string]any{"terms": map[string]any{"fleetId": us.GetFleetIds()}})
		}
		if len(us.GetVins()) > 0 {
			should = append(should, map[string]any{"terms": map[string]any{"vin": us.GetVins()}})
		}
		if len(should) == 0 {
			writeJSON(w, http.StatusOK, []any{})
			return
		}
		filters = append(filters, map[string]any{"bool": map[string]any{"should": should, "minimum_should_match": 1}})
	}
	query, _ := json.Marshal(map[string]any{
		"size":     5000,
		"query":    map[string]any{"bool": map[string]any{"filter": filters}},
		"collapse": map[string]any{"field": "vin"},
		"sort":     []any{map[string]any{"deviceTimestamp": "desc"}},
		"_source":  map[string]any{"excludes": []string{"location"}},
	})
	code, body, err := a.OS.Do(r.Context(), "POST", "/"+a.IndexPattern+"/_search?ignore_unavailable=true", query, "")
	if err != nil || code >= 300 {
		a.Log.Error("snapshot query failed", "status", code, "err", err, "body", string(body))
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "Vehicle history is unavailable right now."})
		return
	}
	var res struct {
		Hits struct {
			Hits []struct {
				Source json.RawMessage `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "Unexpected search response."})
		return
	}
	out := make([]json.RawMessage, 0, len(res.Hits.Hits))
	for _, h := range res.Hits.Hits {
		out = append(out, h.Source)
	}
	writeJSON(w, http.StatusOK, out)
}

// RefreshScopes periodically re-reads permissions for connected users so grant
// changes take effect on open streams without reconnecting.
func (a *API) RefreshScopes(ctx context.Context) {
	t := time.NewTicker(a.ScopeRefresh)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for _, uid := range a.Broker.UserIDs() {
				s, err := a.scope(ctx, uid)
				if err != nil {
					a.Log.Warn("scope refresh failed", "user", uid, "err", err)
					continue
				}
				a.Broker.UpdateScope(uid, ScopeFromProto(s))
			}
		}
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}
