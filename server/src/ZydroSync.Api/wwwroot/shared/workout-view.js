// Detalle de un entrenamiento a partir de su payload original: tarjetas, mapa, parciales por
// km y gráficas. Lo usan la web «Mis carreras» y el panel de administración.
import { h, svg, fmtDateTime, fmtKm, fmtInt, fmtDuration, fmtPace, paceOf, mean } from "./ui.js";

/**
 * Devuelve { node, mount, destroy }. Leaflet necesita el contenedor ya en el documento:
 * se llama a mount() después de insertar node, y a destroy() al cambiar de vista.
 */
export function workoutView(w, { subtitle, actions = [] } = {}) {
  const s = w.series || {};
  const hr = s.heartRate?.v || [];
  const cad = s.cadence?.v || [];
  const pow = s.power?.v || [];

  const card = (label, value, unit) => h("div", { class: "card" },
    h("div", { class: "label" }, label), h("div", { class: "value" }, value, unit ? h("small", {}, ` ${unit}`) : null));

  const cards = h("div", { class: "cards" },
    card("Distancia", fmtKm(w.distanceM), "km"),
    card("Tiempo activo", fmtDuration(w.durationSec)),
    card("Ritmo medio", fmtPace(paceOf(w.durationSec, w.distanceM)), "/km"),
    card("FC media", hr.length ? fmtInt(mean(hr)) : "—", hr.length ? "lpm" : ""),
    card("FC máx", hr.length ? fmtInt(Math.max(...hr)) : "—", hr.length ? "lpm" : ""),
    card("Cadencia", cad.length ? fmtInt(mean(cad)) : "—", cad.length ? "ppm" : ""),
    card("Potencia", pow.length ? fmtInt(mean(pow)) : "—", pow.length ? "W" : ""),
    card("Desnivel +", fmtInt(w.elevationAscendedM), "m"),
    card("Energía", fmtInt(w.activeEnergyKcal), "kcal"),
    card("Pasos", fmtInt(w.stepCount)),
  );

  const details = h("div", { class: "panel pad" }, h("table", {}, h("tbody", {},
    [
      ["Inicio", fmtDateTime(w.startDate)],
      ["Fin", fmtDateTime(w.endDate)],
      ["Total (con pausas)", fmtDuration(w.elapsedSec)],
      ["Zona horaria", w.timeZone || "—"],
      ["Clima", w.weather ? `${w.weather.temperatureC ?? "—"} ºC · ${w.weather.humidityPct ?? "—"} %` : "—"],
      ["Reloj", [w.device?.name, w.source?.productType, w.source?.osVersion].filter(Boolean).join(" · ") || "—"],
      ["Origen", w.source?.name || "—"],
      ["Puntos de ruta", fmtInt(w.route?.t?.length ?? 0)],
      ["Eventos", fmtInt(w.events?.length ?? 0)],
      ["UUID", w.workoutId],
    ].map(([k, v]) => h("tr", {}, h("td", { class: "muted" }, k), h("td", { class: k === "UUID" ? "mono" : "" }, v))))));

  const mapEl = h("div", { class: "map" });
  const charts = h("div", {});
  addChart(charts, "Frecuencia cardíaca", "lpm", s.heartRate, { color: "--hr" });
  addChart(charts, "Ritmo", "min/km", paceSeries(s.speed), { color: "--pace", invert: true, format: fmtPace });
  addChart(charts, "Cadencia", "ppm", s.cadence, { color: "--cad" });
  addChart(charts, "Potencia", "W", s.power, { color: "--pow" });
  if (w.route?.alt?.length) addChart(charts, "Altitud", "m", { t: w.route.t, v: w.route.alt }, { color: "--alt" });
  if (!charts.childNodes.length) charts.append(h("div", { class: "panel empty" }, "Sin series."));

  const node = h("div", {},
    h("h1", {}, `${fmtKm(w.distanceM)} km · ${fmtDateTime(w.startDate)}`),
    h("div", { class: "subtitle" }, subtitle ?? `${w.sport}${w.indoor ? " en cinta" : ""}`),
    cards,
    h("h2", {}, "Ruta"),
    h("div", { class: "layout" }, mapEl, h("div", {}, details, h("h2", {}, "Parciales por km"), splitsTable(w))),
    h("h2", {}, "Series"),
    charts,
    actions.length ? h("h2", {}, "Acciones") : null,
    actions.length ? h("div", { class: "actions" }, actions) : null,
  );

  let map = null;
  return {
    node,
    mount() { map = drawMap(mapEl, w); },
    destroy() { if (map) { map.remove(); map = null; } },
  };
}

// ---------- mapa ----------

function drawMap(el, w) {
  const r = w.route;
  if (!r || !r.lat?.length) {
    el.replaceWith(h("div", { class: "panel empty" }, w.indoor ? "Carrera en cinta: sin ruta." : "Sin ruta GPS."));
    return null;
  }
  if (!window.L) {
    el.replaceWith(h("div", { class: "panel empty" }, "No se pudo cargar el mapa."));
    return null;
  }
  const latlngs = r.lat.map((lat, i) => [lat, r.lon[i]]);
  const map = L.map(el, { scrollWheelZoom: false });
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(map);
  const color = getComputedStyle(document.documentElement).getPropertyValue("--pace").trim() || "#2563eb";
  const line = L.polyline(latlngs, { color, weight: 4 }).addTo(map);
  L.circleMarker(latlngs[0], { radius: 6, color: "#2e7d32", fillOpacity: 1 }).addTo(map).bindTooltip("Salida");
  L.circleMarker(latlngs[latlngs.length - 1], { radius: 6, color: "#c62828", fillOpacity: 1 }).addTo(map).bindTooltip("Llegada");
  map.fitBounds(line.getBounds(), { padding: [20, 20] });
  return map;
}

// ---------- parciales ----------

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000, toRad = Math.PI / 180;
  const dLat = (lat2 - lat1) * toRad, dLon = (lon2 - lon1) * toRad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function splitsTable(w) {
  const r = w.route;
  if (!r || !(r.lat?.length >= 2)) return h("div", { class: "panel empty" }, "Sin ruta.");
  const splits = [];
  let dist = 0, lastT = r.t[0], nextKm = 1000;
  for (let i = 1; i < r.lat.length; i++) {
    dist += haversine(r.lat[i - 1], r.lon[i - 1], r.lat[i], r.lon[i]);
    while (dist >= nextKm) {
      splits.push(r.t[i] - lastT);
      lastT = r.t[i];
      nextKm += 1000;
    }
  }
  const rest = dist - (nextKm - 1000);
  const rows = splits.map((sec, i) => h("tr", {}, h("td", {}, `km ${i + 1}`), h("td", { class: "num" }, fmtPace(sec))));
  if (rest > 50) {
    const sec = r.t[r.t.length - 1] - lastT;
    rows.push(h("tr", {}, h("td", { class: "muted" }, `+${Math.round(rest)} m`), h("td", { class: "num" }, fmtPace(sec / (rest / 1000)))));
  }
  return h("div", { class: "panel table-wrap" }, h("table", {}, h("tbody", {}, rows)));
}

// ---------- gráficas (SVG propio) ----------

function paceSeries(speed) {
  if (!speed?.v?.length) return null;
  const t = [], v = [];
  speed.v.forEach((mps, i) => {
    if (mps > 1) { t.push(speed.t[i]); v.push(1000 / mps); } // < 1 m/s (parado) no tiene ritmo útil
  });
  return { t, v };
}

function percentile(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * p)))];
}

function addChart(container, title, unit, series, { color, invert = false, format = (x) => fmtInt(x) } = {}) {
  if (!series?.v?.length) return;
  const { t, v } = series;
  const n = v.length;

  // Reducción a ~600 puntos por media de cubos: suficiente para 800 px y ligero en el DOM.
  const buckets = Math.min(600, n);
  const xs = [], ys = [];
  for (let b = 0; b < buckets; b++) {
    const from = Math.floor((b * n) / buckets), to = Math.max(from + 1, Math.floor(((b + 1) * n) / buckets));
    let sx = 0, sy = 0;
    for (let i = from; i < to; i++) { sx += t[i]; sy += v[i]; }
    xs.push(sx / (to - from)); ys.push(sy / (to - from));
  }

  // Escala por percentiles 2–98: un pico aislado (p. ej. potencia al arrancar) no aplasta la gráfica.
  const sorted = [...ys].sort((a, b) => a - b);
  let lo = percentile(sorted, 0.02), hi = percentile(sorted, 0.98);
  if (hi - lo < 1e-6) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.08; lo -= pad; hi += pad;
  const x0 = Math.min(...xs), x1 = Math.max(...xs);

  const W = 800, H = 120, L = 44, B = 16;
  const px = (x) => L + ((x - x0) / (x1 - x0 || 1)) * (W - L - 4);
  const py = (y) => {
    const f = (Math.min(hi, Math.max(lo, y)) - lo) / (hi - lo);
    return invert ? 4 + f * (H - B - 8) : H - B - 4 - f * (H - B - 8);
  };

  const g = svg("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
  for (const frac of [0, 0.5, 1]) {
    const y = lo + (hi - lo) * frac;
    g.append(svg("line", { class: "grid", x1: L, x2: W, y1: py(y), y2: py(y) }));
    g.append(svg("text", { class: "axis", x: L - 6, y: py(y) + 3, "text-anchor": "end" }, format(y)));
  }
  const minutes = (x1 - x0) / 60;
  const step = minutes > 120 ? 30 : minutes > 50 ? 15 : minutes > 20 ? 5 : 1;
  for (let m = 0; m <= minutes; m += step) {
    g.append(svg("text", { class: "axis", x: px(x0 + m * 60), y: H - 2, "text-anchor": "middle" }, `${m}′`));
  }
  const points = xs.map((x, i) => `${px(x).toFixed(1)},${py(ys[i]).toFixed(1)}`).join(" ");
  g.append(svg("polyline", { class: "line", points, stroke: `var(${color})` }));

  container.append(h("div", { class: "chart panel pad" },
    h("div", { class: "head" },
      h("strong", {}, title),
      h("span", {}, `media ${format(mean(v))} · mín ${format(Math.min(...v))} · máx ${format(Math.max(...v))} ${unit} · ${n} muestras`)),
    g));
}
