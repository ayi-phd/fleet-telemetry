import { useEffect, useMemo, useState } from "react";
import { latestPositions, type Me, type Telemetry, type VehicleStatus } from "./api";
import { useTelemetryStream, type StreamState } from "./useTelemetryStream";
import { ago, fleetName, isStale, statusLabel } from "./format";
import MapView from "./MapView";
import Battery from "./Battery";

const STATUS_ORDER: VehicleStatus[] = ["FAULT", "DRIVING", "CHARGING", "IDLE", "PARKED"];

export default function Dashboard({ me, onSignOut }: { me: Me; onSignOut: () => void }) {
  const [initial, setInitial] = useState<Telemetry[] | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const { vehicles, state, rate } = useTelemetryStream(initial);
  const [selectedVin, setSelectedVin] = useState<string | null>(null);
  const [fleet, setFleet] = useState<string>("all");
  const [query, setQuery] = useState("");
  const now = useNow(5000);

  useEffect(() => {
    latestPositions()
      .then(setInitial)
      .catch((e: Error) => setHistoryError(e.message));
  }, []);

  const all = useMemo(() => [...vehicles.values()], [vehicles]);
  const fleets = useMemo(() => [...new Set(all.map((v) => v.fleetId))].sort(), [all]);
  const shown = useMemo(() => {
    const q = query.trim().toUpperCase();
    return all
      .filter((v) => (fleet === "all" || v.fleetId === fleet) && (!q || v.vin.includes(q)))
      .sort(
        (a, b) =>
          STATUS_ORDER.indexOf(a.status) - STATUS_ORDER.indexOf(b.status) || a.vin.localeCompare(b.vin),
      );
  }, [all, fleet, query]);

  const counts = useMemo(() => {
    const c: Partial<Record<VehicleStatus, number>> = {};
    for (const v of shown) c[v.status] = (c[v.status] ?? 0) + 1;
    return c;
  }, [shown]);

  const selected = selectedVin ? vehicles.get(selectedVin) ?? null : null;
  const scopeText = me.scope.all
    ? "All fleets"
    : [
        ...me.scope.fleetIds.map(fleetName),
        me.scope.vins.length ? `${me.scope.vins.length} individual vehicle${me.scope.vins.length > 1 ? "s" : ""}` : "",
      ]
        .filter(Boolean)
        .join(", ") || "No vehicles assigned";

  return (
    <div className="shell">
      <aside className="rail">
        <header className="rail-head">
          <div className="identity">
            <p className="identity-name">{me.name}</p>
            <p className="identity-scope">{scopeText}</p>
          </div>
          <button className="button button-quiet" onClick={onSignOut}>Sign out</button>
        </header>

        <LiveBadge state={state} rate={rate} />

        <div className="controls">
          {fleets.length > 1 && (
            <div className="segmented" role="group" aria-label="Filter by fleet">
              <button aria-pressed={fleet === "all"} onClick={() => setFleet("all")}>All</button>
              {fleets.map((f) => (
                <button key={f} aria-pressed={fleet === f} onClick={() => setFleet(f)}>
                  {fleetName(f)}
                </button>
              ))}
            </div>
          )}
          <input
            className="search"
            type="search"
            placeholder="Find a VIN"
            aria-label="Find a vehicle by VIN"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>

        <p className="tally" aria-live="polite">
          {STATUS_ORDER.filter((s) => counts[s]).map((s) => (
            <span key={s} className={`tally-item status-${s.toLowerCase()}`}>
              <span className="dot" /> {counts[s]} {statusLabel[s].toLowerCase()}
            </span>
          ))}
        </p>

        {historyError && <p className="notice">{historyError} Live positions will still appear.</p>}

        <ul className="vehicle-list">
          {shown.length === 0 && (
            <li className="empty">
              {all.length === 0
                ? "Waiting for the first position report. Vehicles appear here as soon as they send telemetry."
                : "No vehicle matches this filter."}
            </li>
          )}
          {shown.map((v) => (
            <li key={v.vin}>
              <button
                className={`vehicle${v.vin === selectedVin ? " vehicle-selected" : ""}${isStale(v, now) ? " vehicle-stale" : ""}`}
                onClick={() => setSelectedVin(v.vin === selectedVin ? null : v.vin)}
                aria-pressed={v.vin === selectedVin}
              >
                <span className={`status-bar status-${v.status.toLowerCase()}`} aria-hidden="true" />
                <span className="vehicle-main">
                  <span className="vin">{v.vin}</span>
                  <span className="vehicle-meta">
                    {statusLabel[v.status]} in {fleetName(v.fleetId)}, {isStale(v, now) ? "no signal " : ""}
                    {ago(v.deviceTimestamp, now)}
                  </span>
                </span>
                <Battery soc={v.batterySOC} charging={v.status === "CHARGING"} />
              </button>
            </li>
          ))}
        </ul>
      </aside>

      <section className="map-wrap">
        <MapView vehicles={shown} selectedVin={selectedVin} onSelect={setSelectedVin} now={now} />
        {selected && <Detail v={selected} now={now} onClose={() => setSelectedVin(null)} />}
      </section>
    </div>
  );
}

function LiveBadge({ state, rate }: { state: StreamState; rate: number }) {
  const text =
    state === "live" ? `Live, ${rate.toFixed(1)} updates/s` : state === "connecting" ? "Connecting to live feed" : "Reconnecting to live feed";
  return (
    <p className={`live live-${state}`} role="status">
      <span className="live-dot" aria-hidden="true" />
      {text}
    </p>
  );
}

function Detail({ v, now, onClose }: { v: Telemetry; now: number; onClose: () => void }) {
  const latency = v.processedTimestamp && v.deviceTimestamp ? v.processedTimestamp - v.deviceTimestamp : null;
  return (
    <div className="detail" role="dialog" aria-label={`Vehicle ${v.vin}`}>
      <div className="detail-head">
        <h2 className="detail-vin">{v.vin}</h2>
        <button className="button button-quiet" onClick={onClose}>Close</button>
      </div>
      <p className={`detail-status status-${v.status.toLowerCase()}`}>
        <span className="dot" /> {statusLabel[v.status]}
        {isStale(v, now) && <span className="detail-stale">No signal for {ago(v.deviceTimestamp, now).replace(" ago", "")}</span>}
      </p>
      <div className="detail-battery">
        <Battery soc={v.batterySOC} charging={v.status === "CHARGING"} />
      </div>
      <dl className="detail-grid">
        <dt>Fleet</dt>
        <dd>{fleetName(v.fleetId)}</dd>
        <dt>Position</dt>
        <dd>{v.lat.toFixed(5)}, {v.lng.toFixed(5)}</dd>
        <dt>Reported</dt>
        <dd>{new Date(v.deviceTimestamp).toLocaleTimeString()}</dd>
        {latency !== null && (
          <>
            <dt>Pipeline delay</dt>
            <dd>{latency} ms</dd>
          </>
        )}
      </dl>
    </div>
  );
}

function useNow(everyMs: number) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), everyMs);
    return () => window.clearInterval(t);
  }, [everyMs]);
  return now;
}
