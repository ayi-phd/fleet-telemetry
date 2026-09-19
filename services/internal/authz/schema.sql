-- Master data (vehicle -> fleet) and authorization grants.
CREATE TABLE IF NOT EXISTS fleets (
    fleet_id   TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vehicles (
    vin        TEXT PRIMARY KEY CHECK (char_length(vin) = 17),
    fleet_id   TEXT REFERENCES fleets (fleet_id) ON DELETE SET NULL,
    model      TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS vehicles_fleet_idx ON vehicles (fleet_id);

CREATE TABLE IF NOT EXISTS users (
    user_id       TEXT PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('admin', 'fleet_manager', 'viewer')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Fleet-level grant: user sees every vehicle currently assigned to the fleet.
CREATE TABLE IF NOT EXISTS user_fleet_grants (
    user_id  TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
    fleet_id TEXT NOT NULL REFERENCES fleets (fleet_id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, fleet_id)
);

-- Vehicle-level grant: user sees one vehicle regardless of its fleet.
CREATE TABLE IF NOT EXISTS user_vehicle_grants (
    user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
    vin     TEXT NOT NULL REFERENCES vehicles (vin) ON DELETE CASCADE,
    PRIMARY KEY (user_id, vin)
);
