// Panel de administración de ZydroSync. Sin dependencias salvo Leaflet (servido localmente).
// Todo el contenido dinámico se inserta como texto (textContent), nunca como HTML.
"use strict";

const TOKEN_KEY = "zydrosync.adminToken";
const appEl = document.getElementById("app");
const crumbsEl = document.getElementById("crumbs");
const logoutEl = document.getElementById("logout");
let token = sessionStorage.getItem(TOKEN_KEY);
let usersCache = null;
let map = null;

// ---------- utilidades DOM ----------

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function svg(tag, attrs, ...children) {
  const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  for (const c of children) el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return el;
}

function render(...nodes) {
  if (map) { map.remove(); map = null; }
  appEl.replaceChildren(...nodes);
}

function crumbs(...items) {
  crumbsEl.replaceChildren(...items.flatMap((item, i) => [
    i > 0 ? h("span", { class: "sep" }, "›") : null,
    item.href ? h("a", { href: item.href }, item.text) : h("span", {}, item.text),
  ]).filter(Boolean));
}

// ---------- formato ----------

const fmtDateTime = (iso) => new Date(iso).toLocaleString("es-ES", { dateStyle: "medium", timeStyle: "short" });
const fmtDate = (iso) => new Date(iso).toLocaleDateString("es-ES", { dateStyle: "medium" });
const fmtKm = (m) => (m == null ? "—" : (m / 1000).toLocaleString("es-ES", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
const fmtInt = (n) => (n == null ? "—" : Math.round(n).toLocaleString("es-ES"));

function fmtDuration(sec) {
  if (sec == null) return "—";
  const s = Math.round(sec), hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  return (hh ? `${hh}:${String(mm).padStart(2, "0")}` : `${mm}`) + `:${String(ss).padStart(2, "0")}`;
}

function fmtPace(secPerKm) {
  if (!secPerKm || !isFinite(secPerKm)) return "—";
  const s = Math.round(secPerKm);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function fmtBytes(b) {
  if (b == null) return "—";
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)} KB`;
  return `${(b / 1024 / 1024).toFixed(1)} MB`;
}

function fmtAgo(iso) {
  if (!iso) return "nunca";
  const sec = (Date.now() - new Date(iso).getTime()) / 1000;
  if (sec < 90) return "hace un momento";
  if (sec < 3600) return `hace ${Math.round(sec / 60)} min`;
  if (sec < 86400) return `hace ${Math.round(sec / 3600)} h`;
  return `hace ${Math.round(sec / 86400)} d`;
}

const mean = (a) => (a && a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);

// ---------- API ----------

async function api(path, options = {}) {
  const res = await fetch(`/admin/api${path}`, {
    ...options,
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...(options.headers || {}) },
  });
  if (res.status === 401 || res.status === 403) {
    logout(res.status === 403 ? "Ese token no es de administración." : "Token no válido o revocado.");
    throw new Error("auth");
  }
  if (res.status === 204) return null;
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch { /* sin cuerpo */ }
    throw new Error(`${res.status} ${detail}`);
  }
  return res.json();
}

async function loadUsers(force) {
  if (!usersCache || force) usersCache = await api("/users");
  return usersCache;
}

// ---------- sesión ----------

function logout(message) {
  token = null;
  usersCache = null;
  sessionStorage.removeItem(TOKEN_KEY);
  logoutEl.hidden = true;
  renderLogin(message);
}

logoutEl.addEventListener("click", () => logout());

function renderLogin(message) {
  crumbs();
  const input = h("input", { type: "password", placeholder: "zsa_…", autocomplete: "off", autofocus: true });
  const submit = () => {
    const value = input.value.trim();
    if (!value) return;
    token = value;
    sessionStorage.setItem(TOKEN_KEY, token);
    location.hash = "#/users";
    route();
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });
  render(h("div", { class: "login panel pad" },
    h("h1", {}, "Acceso de administración"),
    h("p", {}, "Pega un token de tipo admin. Se crea con la CLI del servidor:"),
    h("p", { class: "mono" }, "tokens create <email> admin"),
    input,
    h("div", { class: "actions", style: "margin-top:12px" }, h("button", { class: "primary", onclick: submit }, "Entrar")),
    h("p", { class: "muted", style: "font-size:12px" }, "Se guarda solo en esta pestaña (sessionStorage) y se borra al cerrarla."),
    message ? h("div", { class: "error" }, message) : null,
  ));
}

// ---------- vistas ----------

async function renderUsers() {
  crumbs({ text: "Usuarios" });
  const users = await loadUsers(true);
  const totalWorkouts = users.reduce((n, u) => n + u.workouts, 0);
  const rows = users.map((u) => {
    const active = u.tokens.filter((t) => !t.revokedAt).length;
    return h("tr", { class: "link", onclick: () => (location.hash = `#/users/${u.id}`) },
      h("td", {}, u.email),
      h("td", {}, fmtDate(u.createdAt)),
      h("td", { class: "num" }, u.workouts),
      h("td", {}, u.lastWorkoutStart ? fmtDateTime(u.lastWorkoutStart) : "—"),
      h("td", { class: "num" }, fmtBytes(u.dataBytes)),
      h("td", { class: "num" }, `${active} / ${u.tokens.length}`));
  });
  render(
    h("h1", {}, "Usuarios"),
    h("div", { class: "subtitle" }, `${users.length} usuarios · ${totalWorkouts} entrenamientos`),
    h("div", { class: "panel table-wrap" }, users.length === 0
      ? h("div", { class: "empty" }, "Sin usuarios. Crea uno con la CLI: users add <email>")
      : h("table", {},
        h("thead", {}, h("tr", {}, ["Email", "Alta", "Entrenos", "Último", "Datos", "Tokens activos"]
          .map((t, i) => h("th", { class: i >= 2 && i !== 3 ? "num" : "" }, t)))),
        h("tbody", {}, rows))),
  );
}

async function renderUser(userId) {
  const users = await loadUsers();
  const user = users.find((u) => u.id === userId);
  if (!user) return renderNotFound();
  crumbs({ text: "Usuarios", href: "#/users" }, { text: user.email });
  const workouts = await api(`/users/${userId}/workouts`);

  const tokenRows = user.tokens.map((t) => h("tr", {},
    h("td", {}, h("span", { class: "badge kind" }, t.kind)),
    h("td", { class: "mono" }, `${t.prefix}…`),
    h("td", {}, t.name),
    h("td", {}, fmtDate(t.createdAt)),
    h("td", {}, fmtAgo(t.lastUsedAt)),
    h("td", {}, t.revokedAt ? h("span", { class: "badge off" }, "revocado") : h("span", { class: "badge ok" }, "activo")),
    h("td", {}, t.revokedAt ? null : h("button", {
      class: "danger",
      onclick: async () => {
        if (!confirm(`¿Revocar el token ${t.prefix}… (${t.kind}, "${t.name}")? Dejará de funcionar inmediatamente.`)) return;
        await api(`/tokens/${t.id}/revoke`, { method: "POST" });
        usersCache = null;
        renderUser(userId);
      },
    }, "Revocar"))));

  const workoutRows = workouts.map((w) => h("tr", { class: "link", onclick: () => (location.hash = `#/users/${userId}/workouts/${w.workoutId}`) },
    h("td", {}, fmtDateTime(w.startDate)),
    h("td", {}, w.sport + (w.indoor ? " (cinta)" : "")),
    h("td", { class: "num" }, fmtKm(w.distanceM)),
    h("td", { class: "num" }, fmtDuration(w.durationSec)),
    h("td", { class: "num" }, w.distanceM ? fmtPace(w.durationSec / (w.distanceM / 1000)) : "—"),
    h("td", { class: "num" }, fmtInt(w.routePoints)),
    h("td", { class: "num" }, fmtBytes(w.payloadGzipBytes)),
    h("td", { class: "mono" }, w.sourceProductType || "—")));

  render(
    h("h1", {}, user.email),
    h("div", { class: "subtitle mono" }, user.id),
    h("h2", {}, `Entrenamientos (${workouts.length})`),
    h("div", { class: "panel table-wrap" }, workouts.length === 0
      ? h("div", { class: "empty" }, "Sin entrenamientos.")
      : h("table", {},
        h("thead", {}, h("tr", {}, ["Inicio", "Deporte", "km", "Duración", "Ritmo /km", "Ruta", "gzip", "Reloj"]
          .map((t, i) => h("th", { class: i >= 2 && i <= 6 ? "num" : "" }, t)))),
        h("tbody", {}, workoutRows))),
    h("h2", {}, "Tokens"),
    h("div", { class: "panel table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Tipo", "Prefijo", "Nombre", "Creado", "Último uso", "Estado", ""].map((t) => h("th", {}, t)))),
      h("tbody", {}, tokenRows))),
  );
}

async function renderWorkout(userId, workoutId) {
  const users = await loadUsers();
  const user = users.find((u) => u.id === userId);
  if (!user) return renderNotFound();
  const w = await api(`/users/${userId}/workouts/${workoutId}`);
  crumbs({ text: "Usuarios", href: "#/users" }, { text: user.email, href: `#/users/${userId}` }, { text: fmtDateTime(w.startDate) });

  const s = w.series || {};
  const hr = s.heartRate?.v || [];
  const cad = s.cadence?.v || [];
  const pow = s.power?.v || [];
  const paceAvg = w.distanceM ? w.durationSec / (w.distanceM / 1000) : null;

  const card = (label, value, unit) => h("div", { class: "card" },
    h("div", { class: "label" }, label), h("div", { class: "value" }, value, unit ? h("small", {}, ` ${unit}`) : null));

  const cards = h("div", { class: "cards" },
    card("Distancia", fmtKm(w.distanceM), "km"),
    card("Tiempo activo", fmtDuration(w.durationSec)),
    card("Ritmo medio", fmtPace(paceAvg), "/km"),
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

  const mapEl = h("div", { id: "map" });
  const charts = h("div", {});
  const actions = h("div", { class: "actions" },
    h("button", { onclick: () => downloadJson(w) }, "Descargar JSON"),
    h("button", {
      class: "danger",
      onclick: async () => {
        if (!confirm("¿Borrar este entrenamiento del servidor? No se puede deshacer. (La app puede volver a enviarlo con «Borrar enviadas y volver a enviar».)")) return;
        await api(`/users/${userId}/workouts/${workoutId}`, { method: "DELETE" });
        usersCache = null;
        location.hash = `#/users/${userId}`;
      },
    }, "Borrar del servidor"));

  render(
    h("h1", {}, `${fmtKm(w.distanceM)} km · ${fmtDateTime(w.startDate)}`),
    h("div", { class: "subtitle" }, `${w.sport}${w.indoor ? " en cinta" : ""} · ${user.email}`),
    cards,
    h("h2", {}, "Ruta"),
    h("div", { class: "layout" }, mapEl, h("div", {}, details, h("h2", {}, "Parciales por km"), splitsTable(w))),
    h("h2", {}, "Series"),
    charts,
    h("h2", {}, "Acciones"),
    actions,
  );

  drawMap(mapEl, w);
  addChart(charts, "Frecuencia cardíaca", "lpm", s.heartRate, { color: "--hr" });
  addChart(charts, "Ritmo", "min/km", paceSeries(s.speed), { color: "--pace", invert: true, format: fmtPace });
  addChart(charts, "Cadencia", "ppm", s.cadence, { color: "--cad" });
  addChart(charts, "Potencia", "W", s.power, { color: "--pow" });
  if (w.route?.alt?.length) addChart(charts, "Altitud", "m", { t: w.route.t, v: w.route.alt }, { color: "--alt" });
  if (!charts.childNodes.length) charts.append(h("div", { class: "panel empty" }, "Sin series."));
}

function renderNotFound() {
  crumbs({ text: "Usuarios", href: "#/users" });
  render(h("div", { class: "panel empty" }, "No encontrado."));
}

// ---------- mapa ----------

function drawMap(el, w) {
  const r = w.route;
  if (!r || !r.lat?.length) {
    el.replaceWith(h("div", { class: "panel empty" }, w.indoor ? "Carrera en cinta: sin ruta." : "Sin ruta GPS."));
    return;
  }
  if (!window.L) {
    el.replaceWith(h("div", { class: "panel empty" }, "No se pudo cargar el mapa."));
    return;
  }
  const latlngs = r.lat.map((lat, i) => [lat, r.lon[i]]);
  map = L.map(el, { scrollWheelZoom: false });
  L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(map);
  const line = L.polyline(latlngs, { color: getComputedStyle(document.documentElement).getPropertyValue("--pace").trim() || "#2563eb", weight: 4 }).addTo(map);
  L.circleMarker(latlngs[0], { radius: 6, color: "#2e7d32", fillOpacity: 1 }).addTo(map).bindTooltip("Salida");
  L.circleMarker(latlngs[latlngs.length - 1], { radius: 6, color: "#c62828", fillOpacity: 1 }).addTo(map).bindTooltip("Llegada");
  map.fitBounds(line.getBounds(), { padding: [20, 20] });
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
  if (!r || r.lat?.length < 2) return h("div", { class: "panel empty" }, "Sin ruta.");
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

  const avg = mean(v);
  container.append(h("div", { class: "chart panel pad" },
    h("div", { class: "head" },
      h("strong", {}, title),
      h("span", {}, `media ${format(avg)} · mín ${format(Math.min(...v))} · máx ${format(Math.max(...v))} ${unit} · ${n} muestras`)),
    g));
}

// ---------- descargas ----------

function downloadJson(w) {
  const blob = new Blob([JSON.stringify(w, null, 2)], { type: "application/json" });
  const a = h("a", { href: URL.createObjectURL(blob), download: `zydrosync-${w.workoutId}.json` });
  document.body.append(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

// ---------- rutas ----------

async function route() {
  if (!token) return renderLogin();
  logoutEl.hidden = false;
  const parts = (location.hash.replace(/^#\/?/, "") || "users").split("/");
  try {
    if (parts[0] === "users" && parts.length === 1) return await renderUsers();
    if (parts[0] === "users" && parts.length === 2) return await renderUser(parts[1]);
    if (parts[0] === "users" && parts[2] === "workouts" && parts.length === 4) return await renderWorkout(parts[1], parts[3]);
    renderNotFound();
  } catch (e) {
    if (e.message !== "auth") render(h("div", { class: "panel pad error" }, `Error: ${e.message}`));
  }
}

window.addEventListener("hashchange", route);
route();
