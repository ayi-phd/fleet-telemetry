export type VehicleStatus = "DRIVING" | "CHARGING" | "PARKED" | "IDLE" | "FAULT" | "UNSPECIFIED";

export interface Telemetry {
  eventId: string;
  vin: string;
  fleetId: string;
  lng: number;
  lat: number;
  status: VehicleStatus;
  batterySOC: number;
  deviceTimestamp: number;
  ingestTimestamp: number;
  processedTimestamp: number;
}

export interface Me {
  userId: string;
  name: string;
  role: string;
  scope: { all: boolean; fleetIds: string[]; vins: string[] };
}

// Auth uses the HttpOnly session cookie set by /auth/login; same-origin fetches and
// EventSource send it automatically, so no token is ever exposed to JavaScript.
async function errorMessage(r: Response, fallback: string): Promise<string> {
  try {
    const body = await r.json();
    return body.error ?? fallback;
  } catch {
    return fallback;
  }
}

export async function getMe(): Promise<Me | null> {
  const r = await fetch("/api/me");
  if (r.status === 401) return null;
  if (!r.ok) throw new Error(await errorMessage(r, "Could not load your profile."));
  return r.json();
}

export async function login(username: string, password: string): Promise<void> {
  const r = await fetch("/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });
  if (!r.ok) throw new Error(await errorMessage(r, "Sign-in failed."));
}

export async function logout(): Promise<void> {
  await fetch("/auth/logout", { method: "POST" });
}

export async function latestPositions(): Promise<Telemetry[]> {
  const r = await fetch("/api/vehicles/latest");
  if (!r.ok) throw new Error(await errorMessage(r, "Could not load last known positions."));
  return r.json();
}
