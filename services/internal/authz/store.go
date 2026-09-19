package authz

import (
	"context"
	_ "embed"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"

	authzv1 "github.com/example/fleet-telemetry/gen/authz/v1"
)

//go:embed schema.sql
var schemaSQL string

var ErrInvalidCredentials = errors.New("invalid credentials")

var dummyHash, _ = bcrypt.GenerateFromPassword([]byte("not-a-real-password"), bcrypt.DefaultCost)

type Store struct{ DB *pgxpool.Pool }

type User struct {
	ID, Username, DisplayName, Role string
}

// Migrate applies the schema under an advisory lock so concurrent replicas don't race.
func (s *Store) Migrate(ctx context.Context) error {
	conn, err := s.DB.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock(727001)"); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock(727001)")
	_, err = conn.Exec(ctx, schemaSQL)
	return err
}

func (s *Store) Authenticate(ctx context.Context, username, password string) (*User, error) {
	var u User
	var hash string
	err := s.DB.QueryRow(ctx,
		`SELECT user_id, username, display_name, role, password_hash FROM users WHERE username = $1`, username).
		Scan(&u.ID, &u.Username, &u.DisplayName, &u.Role, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		_ = bcrypt.CompareHashAndPassword(dummyHash, []byte(password)) // equalize timing for unknown users
		return nil, ErrInvalidCredentials
	}
	if err != nil {
		return nil, err
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		return nil, ErrInvalidCredentials
	}
	return &u, nil
}

func (s *Store) Scope(ctx context.Context, userID string) (*authzv1.UserScope, error) {
	out := &authzv1.UserScope{UserId: userID}
	var role string
	if err := s.DB.QueryRow(ctx, `SELECT role FROM users WHERE user_id = $1`, userID).Scan(&role); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil // unknown users see nothing
		}
		return nil, err
	}
	if role == "admin" {
		out.AllFleets = true
		return out, nil
	}
	fleets, err := s.strings(ctx, `SELECT fleet_id FROM user_fleet_grants WHERE user_id = $1 ORDER BY fleet_id`, userID)
	if err != nil {
		return nil, err
	}
	vins, err := s.strings(ctx, `SELECT vin FROM user_vehicle_grants WHERE user_id = $1 ORDER BY vin`, userID)
	if err != nil {
		return nil, err
	}
	out.FleetIds, out.Vins = fleets, vins
	return out, nil
}

func (s *Store) VehicleFleets(ctx context.Context) (map[string]string, error) {
	rows, err := s.DB.Query(ctx, `SELECT vin, fleet_id FROM vehicles WHERE fleet_id IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var vin, fleet string
		if err := rows.Scan(&vin, &fleet); err != nil {
			return nil, err
		}
		out[vin] = fleet
	}
	return out, rows.Err()
}

func (s *Store) UpsertFleet(ctx context.Context, fleetID, name string) error {
	_, err := s.DB.Exec(ctx, `INSERT INTO fleets (fleet_id, name) VALUES ($1, $2)
		ON CONFLICT (fleet_id) DO UPDATE SET name = EXCLUDED.name`, fleetID, name)
	return err
}

func (s *Store) UpsertVehicle(ctx context.Context, vin, fleetID, model string) error {
	_, err := s.DB.Exec(ctx, `INSERT INTO vehicles (vin, fleet_id, model) VALUES ($1, $2, NULLIF($3, ''))
		ON CONFLICT (vin) DO UPDATE SET fleet_id = EXCLUDED.fleet_id,
		    model = COALESCE(EXCLUDED.model, vehicles.model), updated_at = now()`, vin, fleetID, model)
	return err
}

func (s *Store) UpsertUser(ctx context.Context, id, username, display, role, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	_, err = s.DB.Exec(ctx, `INSERT INTO users (user_id, username, display_name, password_hash, role)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (user_id) DO UPDATE SET display_name = EXCLUDED.display_name,
		    password_hash = EXCLUDED.password_hash, role = EXCLUDED.role`, id, username, display, string(hash), role)
	return err
}

func (s *Store) GrantFleet(ctx context.Context, userID, fleetID string) error {
	_, err := s.DB.Exec(ctx, `INSERT INTO user_fleet_grants VALUES ($1, $2) ON CONFLICT DO NOTHING`, userID, fleetID)
	return err
}

func (s *Store) GrantVehicle(ctx context.Context, userID, vin string) error {
	_, err := s.DB.Exec(ctx, `INSERT INTO user_vehicle_grants VALUES ($1, $2) ON CONFLICT DO NOTHING`, userID, vin)
	return err
}

func (s *Store) strings(ctx context.Context, q string, args ...any) ([]string, error) {
	rows, err := s.DB.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}

// Seed creates demo fleets, vehicles matching the simulator's VINs, and demo users.
func (s *Store) Seed(ctx context.Context, vehicleCount int, password string) error {
	fleets := []struct{ id, name string }{
		{"fleet-north", "North depot"}, {"fleet-south", "South depot"}, {"fleet-east", "East depot"},
	}
	for _, f := range fleets {
		if err := s.UpsertFleet(ctx, f.id, f.name); err != nil {
			return err
		}
	}
	for i := 1; i <= vehicleCount; i++ {
		// DO NOTHING: keep reassignments made through the admin API across restarts.
		if _, err := s.DB.Exec(ctx, `INSERT INTO vehicles (vin, fleet_id, model) VALUES ($1, $2, 'Demo EV')
			ON CONFLICT (vin) DO NOTHING`, SimVIN(i), fleets[(i-1)%len(fleets)].id); err != nil {
			return err
		}
	}
	users := []struct{ id, username, name, role string }{
		{"u-admin", "admin", "Operations admin", "admin"},
		{"u-north", "north-manager", "North depot manager", "fleet_manager"},
		{"u-south", "south-viewer", "South depot viewer", "viewer"},
		{"u-vehicle", "vehicle-viewer", "Single-vehicle viewer", "viewer"},
	}
	for _, u := range users {
		if err := s.UpsertUser(ctx, u.id, u.username, u.name, u.role, password); err != nil {
			return err
		}
	}
	if err := s.GrantFleet(ctx, "u-north", "fleet-north"); err != nil {
		return err
	}
	if err := s.GrantFleet(ctx, "u-south", "fleet-south"); err != nil {
		return err
	}
	for _, i := range []int{3, 6} { // two vehicles from fleet-east, granted individually
		if i <= vehicleCount {
			if err := s.GrantVehicle(ctx, "u-vehicle", SimVIN(i)); err != nil {
				return err
			}
		}
	}
	return nil
}

// SimVIN must match the Terraform format("SIM%014d", i) used to create IoT things.
func SimVIN(i int) string { return fmt.Sprintf("SIM%014d", i) }
