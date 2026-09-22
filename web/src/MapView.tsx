import { useEffect, useRef } from "react";
import L from "leaflet";
import type { Telemetry } from "./api";
import { isStale, statusColor } from "./format";

interface Props {
  vehicles: Telemetry[];
  selectedVin: string | null;
  onSelect: (vin: string) => void;
  now: number;
}

export default function MapView({ vehicles, selectedVin, onSelect, now }: Props) {
  const container = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const markers = useRef(new Map<string, L.CircleMarker>());
  const fitted = useRef(false);
  const onSelectRef = useRef(onSelect);
  onSelectRef.current = onSelect;

  useEffect(() => {
    if (!container.current) return;
    const m = L.map(container.current, { zoomControl: false, attributionControl: true }).setView([37.7749, -122.4194], 11);
    L.control.zoom({ position: "bottomright" }).addTo(m);
    // CARTO's free "light_all" basemap now watermarks "API KEY REQUIRED" over tiles
    // served without one; OSM's own tile server has no such requirement.
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      subdomains: "abc",
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(m);
    map.current = m;
    return () => {
      m.remove();
      map.current = null;
      markers.current.clear();
      fitted.current = false;
    };
  }, []);

  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const seen = new Set<string>();
    for (const v of vehicles) {
      seen.add(v.vin);
      const stale = isStale(v, now);
      const selected = v.vin === selectedVin;
      const style: L.CircleMarkerOptions = {
        radius: selected ? 10 : 7,
        weight: selected ? 3 : 2,
        color: selected ? "#15222d" : "#fbfcfc",
        fillColor: stale ? "#8d99a3" : (statusColor[v.status] ?? statusColor.UNSPECIFIED),
        fillOpacity: stale ? 0.55 : 1,
        className: `vehicle-marker status-${v.status.toLowerCase()}`,
      };
      let marker = markers.current.get(v.vin);
      if (!marker) {
        marker = L.circleMarker([v.lat, v.lng], style)
          .bindTooltip(v.vin, { direction: "top", offset: [0, -8] })
          .on("click", () => onSelectRef.current(v.vin))
          .addTo(m);
        markers.current.set(v.vin, marker);
      } else {
        marker.setLatLng([v.lat, v.lng]).setStyle(style);
      }
      if (selected) marker.bringToFront();
    }
    for (const [vin, marker] of markers.current) {
      if (!seen.has(vin)) {
        marker.remove();
        markers.current.delete(vin);
      }
    }
    if (!fitted.current && vehicles.length > 0) {
      m.fitBounds(L.latLngBounds(vehicles.map((v) => [v.lat, v.lng] as [number, number])), { padding: [48, 48], maxZoom: 14 });
      fitted.current = true;
    }
  }, [vehicles, selectedVin, now]);

  useEffect(() => {
    const v = vehicles.find((x) => x.vin === selectedVin);
    if (v && map.current) map.current.panTo([v.lat, v.lng], { animate: true });
    // pan only when the selection changes, not on every position update
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedVin]);

  return <div ref={container} className="map" role="application" aria-label="Map of vehicle positions" />;
}
