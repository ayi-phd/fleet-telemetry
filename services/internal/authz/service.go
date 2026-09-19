package authz

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
	"github.com/example/fleet-telemetry/internal/platform"
)

// GRPC implements the internal AuthzService used by dashboard-api.
type GRPC struct {
	authzv1.UnimplementedAuthzServiceServer
	Store *Store
}

func (g *GRPC) GetUserScope(ctx context.Context, req *authzv1.GetUserScopeRequest) (*authzv1.UserScope, error) {
	if req.GetUserId() == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id required")
	}
	s, err := g.Store.Scope(ctx, req.GetUserId())
	if err != nil {
		return nil, status.Error(codes.Unavailable, err.Error())
	}
	return s, nil
}

func (g *GRPC) CheckAccess(ctx context.Context, req *authzv1.CheckAccessRequest) (*authzv1.CheckAccessResponse, error) {
	s, err := g.GetUserScope(ctx, &authzv1.GetUserScopeRequest{UserId: req.GetUserId()})
	if err != nil {
		return nil, err
	}
	allowed := s.GetAllFleets() ||
		(req.GetFleetId() != "" && slices.Contains(s.GetFleetIds(), req.GetFleetId())) ||
		(req.GetVin() != "" && slices.Contains(s.GetVins(), req.GetVin()))
	return &authzv1.CheckAccessResponse{Allowed: allowed}, nil
}

// HTTP serves login/logout (via the web gateway) and minimal admin endpoints.
type HTTP struct {
	Store        *Store
	Syncer       *Syncer
	JWTKey       []byte
	TokenTTL     time.Duration
	SecureCookie bool
	Log          *slog.Logger
}

func (h *HTTP) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /auth/login", h.login)
	mux.HandleFunc("POST /auth/logout", h.logout)
	mux.HandleFunc("POST /admin/vehicles", h.admin(h.upsertVehicle))
	mux.HandleFunc("POST /admin/grants", h.admin(h.grant))
	return mux
}

func (h *HTTP) login(w http.ResponseWriter, r *http.Request) {
	var req struct{ Username, Password string }
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Send a username and password."})
		return
	}
	u, err := h.Store.Authenticate(r.Context(), req.Username, req.Password)
	if errors.Is(err, ErrInvalidCredentials) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "That username and password don't match."})
		return
	}
	if err != nil {
		h.Log.Error("login failed", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "Sign-in is unavailable. Try again shortly."})
		return
	}
	token, exp, err := platform.IssueToken(h.JWTKey, u.ID, u.DisplayName, u.Role, h.TokenTTL)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "Could not create a session."})
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: platform.SessionCookie, Value: token, Path: "/", Expires: exp,
		HttpOnly: true, Secure: h.SecureCookie, SameSite: http.SameSiteStrictMode,
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token, "expiresAt": exp.UnixMilli(),
		"user": map[string]string{"userId": u.ID, "name": u.DisplayName, "role": u.Role},
	})
}

func (h *HTTP) logout(w http.ResponseWriter, _ *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: platform.SessionCookie, Value: "", Path: "/", MaxAge: -1,
		HttpOnly: true, Secure: h.SecureCookie, SameSite: http.SameSiteStrictMode})
	w.WriteHeader(http.StatusNoContent)
}

func (h *HTTP) admin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := platform.ParseToken(h.JWTKey, platform.TokenFromRequest(r))
		if err != nil || c.Role != "admin" {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "Admin role required."})
			return
		}
		next(w, r)
	}
}

func (h *HTTP) upsertVehicle(w http.ResponseWriter, r *http.Request) {
	var req struct{ VIN, FleetID, Model string }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || len(req.VIN) != 17 || req.FleetID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Provide a 17-character vin and a fleetId."})
		return
	}
	if err := h.Store.UpsertVehicle(r.Context(), req.VIN, req.FleetID, req.Model); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if err := h.Syncer.SetOne(r.Context(), req.VIN, req.FleetID); err != nil {
		h.Log.Warn("redis update failed; periodic sync will retry", "err", err)
	}
	writeJSON(w, http.StatusOK, map[string]string{"vin": req.VIN, "fleetId": req.FleetID})
}

func (h *HTTP) grant(w http.ResponseWriter, r *http.Request) {
	var req struct{ UserID, FleetID, VIN string }
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserID == "" || (req.FleetID == "") == (req.VIN == "") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Provide userId and exactly one of fleetId or vin."})
		return
	}
	var err error
	if req.FleetID != "" {
		err = h.Store.GrantFleet(r.Context(), req.UserID, req.FleetID)
	} else {
		err = h.Store.GrantVehicle(r.Context(), req.UserID, req.VIN)
	}
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
