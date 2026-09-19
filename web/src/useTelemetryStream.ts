import { useEffect, useRef, useState } from "react";
import type { Telemetry } from "./api";

export type StreamState = "connecting" | "live" | "reconnecting";

const FLUSH_MS = 250;

/**
 * Subscribes to /api/stream (SSE). Events are buffered and applied to state every
 * 250 ms so a busy fleet doesn't re-render the map on every message.
 */
export function useTelemetryStream(initial: Telemetry[] | null) {
  const [vehicles, setVehicles] = useState<Map<string, Telemetry>>(new Map());
  const [state, setState] = useState<StreamState>("connecting");
  const [rate, setRate] = useState(0);
  const pending = useRef<Telemetry[]>([]);
  const arrivals = useRef<number[]>([]);

  useEffect(() => {
    if (!initial) return;
    setVehicles((prev) => merge(prev, initial));
  }, [initial]);

  useEffect(() => {
    const es = new EventSource("/api/stream");
    es.addEventListener("ready", () => setState("live"));
    es.addEventListener("telemetry", (e) => {
      try {
        pending.current.push(JSON.parse((e as MessageEvent).data));
        arrivals.current.push(Date.now());
      } catch {
        /* ignore malformed event */
      }
    });
    es.onerror = () => setState("reconnecting"); // EventSource retries on its own

    const timer = window.setInterval(() => {
      const now = Date.now();
      arrivals.current = arrivals.current.filter((t) => now - t < 5000);
      setRate(arrivals.current.length / 5);
      if (pending.current.length === 0) return;
      const batch = pending.current;
      pending.current = [];
      setVehicles((prev) => merge(prev, batch));
    }, FLUSH_MS);

    return () => {
      es.close();
      window.clearInterval(timer);
    };
  }, []);

  return { vehicles, state, rate };
}

function merge(prev: Map<string, Telemetry>, events: Telemetry[]): Map<string, Telemetry> {
  const next = new Map(prev);
  for (const ev of events) {
    const cur = next.get(ev.vin);
    if (!cur || ev.deviceTimestamp >= cur.deviceTimestamp) next.set(ev.vin, ev);
  }
  return next;
}
