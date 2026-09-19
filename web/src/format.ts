import type { Telemetry, VehicleStatus } from "./api";

export const STALE_AFTER_MS = 60_000;

export const statusLabel: Record<VehicleStatus, string> = {
  DRIVING: "Driving",
  CHARGING: "Charging",
  PARKED: "Parked",
  IDLE: "Idle",
  FAULT: "Fault",
  UNSPECIFIED: "Unknown",
};

export function isStale(v: Telemetry, now: number) {
  return now - v.deviceTimestamp > STALE_AFTER_MS;
}

export function ago(ts: number, now: number): string {
  const s = Math.max(0, Math.round((now - ts) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  return `${Math.round(m / 60)} h ago`;
}

export function fleetName(id: string) {
  if (id === "UNASSIGNED") return "Unassigned";
  return id.replace(/^fleet-/, "").replace(/^\w/, (c) => c.toUpperCase());
}

// SVG presentation attributes (used by Leaflet markers) can't resolve CSS variables,
// so status colors live here and are mirrored in styles.css.
export const statusColor: Record<VehicleStatus, string> = {
  DRIVING: "#1f5fd1",
  CHARGING: "#0a8a62",
  PARKED: "#5c6975",
  IDLE: "#b7791f",
  FAULT: "#c62f3b",
  UNSPECIFIED: "#8d99a3",
};
