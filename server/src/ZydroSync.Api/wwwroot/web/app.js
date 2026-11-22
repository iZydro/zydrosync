// «Mis carreras»: los entrenamientos del propio usuario, leídos de la API pública
// (/v1/workouts) con un token de tipo web, de solo lectura.
import { h, setCrumbs, fmtDateTime, fmtKm, fmtDuration, fmtHours, fmtPace, paceOf, downloadJson, loginForm } from "/shared/ui.js";
import { workoutView } from "/shared/workout-view.js";

const TOKEN_KEY = "zydrosync.webToken";
const PAGE = 500;
const appEl = document.getElementById("app");
const crumbsEl = document.getElementById("crumbs");
const logoutEl = document.getElementById("logout");
let token = sessionStorage.getItem(TOKEN_KEY);
let workouts = null; // resúmenes, del más reciente al más antiguo
let year = null;     // filtro de la lista
let current = null;  // vista con recursos que liberar (el mapa)

function render(...nodes) {
  current?.destroy();
  current = null;
  appEl.replaceChildren(...nodes);
}

const crumbs = (...items) => setCrumbs(crumbsEl, items);

class AuthError extends Error {}

async function api(path) {
  const res = await fetch(path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
  if (res.status === 401) throw new AuthError("Token no válido o revocado.");
  if (res.status === 403) throw new AuthError("Ese token no sirve aquí: usa uno de tipo web (zsw_…).");
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch { /* sin cuerpo */ }
    throw new Error(`${res.status} ${detail}`);
  }
  return res.json();
}

/** Todas las páginas, siguiendo el cursor serverId. */
async function loadWorkouts(force) {
  if (workouts && !force) return workouts;
  const all = [];
  let after = null;
  do {
    const page = await api(`/v1/workouts?limit=${PAGE}${after ? `&after=${encodeURIComponent(after)}` : ""}`);
    all.push(...page.items);
    after = page.nextAfter;
  } while (after);
  workouts = all.sort((a, b) => new Date(b.startDate) - new Date(a.startDate));
  return workouts;
}

// ---------- sesión ----------

function logout(message) {
  token = null;
  workouts = null;
  sessionStorage.removeItem(TOKEN_KEY);
  logoutEl.hidden = true;
  renderLogin(message);
}

logoutEl.addEventListener("click", () => logout());

function renderLogin(message) {
  crumbs();
  render(loginForm({
    title: "Mis carreras",
    intro: "Pega tu token web (zsw_…). Es de solo lectura: con él se ven tus carreras, pero no se pueden subir ni borrar.",
    placeholder: "zsw_…",
    message,
    onSubmit(value) {
      token = value;
      sessionStorage.setItem(TOKEN_KEY, token);
      location.hash = "#/";
      route();
    },
  }));
}

// ---------- vistas ----------

function totals(list) {
  const distance = list.reduce((n, w) => n + (w.distanceM || 0), 0);
  const duration = list.reduce((n, w) => n + (w.durationSec || 0), 0);
  return { count: list.length, distance, duration, longest: Math.max(0, ...list.map((w) => w.distanceM || 0)) };
}

function summaryCards(t) {
  const card = (label, value, unit) => h("div", { class: "card" },
    h("div", { class: "label" }, label), h("div", { class: "value" }, value, unit ? h("small", {}, ` ${unit}`) : null));
  return h("div", { class: "cards" },
    card("Carreras", t.count),
    card("Distancia", fmtKm(t.distance), "km"),
    card("Tiempo", fmtHours(t.duration)),
    card("Ritmo medio", fmtPace(paceOf(t.duration, t.distance)), "/km"),
    card("Más larga", fmtKm(t.longest), "km"));
}

async function renderList() {
  crumbs({ text: "Mis carreras" });
  const all = await loadWorkouts(true);
  if (all.length === 0) {
    return render(h("h1", {}, "Mis carreras"),
      h("div", { class: "panel empty" }, "Aún no hay carreras. Se suben desde la app ZydroSync del iPhone."));
  }

  const years = [...new Set(all.map((w) => new Date(w.startDate).getFullYear()))].sort((a, b) => b - a);
  if (year !== "all" && !years.includes(year)) year = years[0];
  const list = year === "all" ? all : all.filter((w) => new Date(w.startDate).getFullYear() === year);

  const yearButtons = h("div", { class: "years" },
    years.map((y) => h("button", { class: y === year ? "active" : "", onclick: () => { year = y; renderList(); } }, String(y))),
    years.length > 1 ? h("button", { class: year === "all" ? "active" : "", onclick: () => { year = "all"; renderList(); } }, "Todas") : null);

  const rows = [];
  let lastMonth = null;
  for (const w of list) {
    const d = new Date(w.startDate);
    const month = d.toLocaleDateString("es-ES", { month: "long", year: "numeric" });
    if (month !== lastMonth) {
      rows.push(h("tr", { class: "month" }, h("td", { colspan: 6 }, month)));
      lastMonth = month;
    }
    rows.push(h("tr", { class: "link", onclick: () => (location.hash = `#/w/${w.workoutId}`) },
      h("td", {}, fmtDateTime(w.startDate)),
      h("td", { class: "num" }, fmtKm(w.distanceM)),
      h("td", { class: "num" }, fmtDuration(w.durationSec)),
      h("td", { class: "num" }, fmtPace(paceOf(w.durationSec, w.distanceM))),
      h("td", {}, w.indoor ? "cinta" : w.routePoints ? "GPS" : "—"),
      h("td", { class: "mono" }, w.sourceProductType || "—")));
  }

  render(
    h("h1", {}, "Mis carreras"),
    h("div", { class: "subtitle" }, `${all.length} carreras en ZydroSync`),
    yearButtons,
    summaryCards(totals(list)),
    h("h2", {}, year === "all" ? "Todas" : String(year)),
    h("div", { class: "panel table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Fecha", "km", "Tiempo", "Ritmo /km", "Ruta", "Reloj"]
        .map((t, i) => h("th", { class: i >= 1 && i <= 3 ? "num" : "" }, t)))),
      h("tbody", {}, rows))),
  );
}

async function renderWorkout(workoutId) {
  const w = await api(`/v1/workouts/${encodeURIComponent(workoutId)}`);
  crumbs({ text: "Mis carreras", href: "#/" }, { text: fmtDateTime(w.startDate) });
  const view = workoutView(w, { actions: [h("button", { onclick: () => downloadJson(w) }, "Descargar JSON")] });
  render(view.node);
  current = view;
  view.mount();
  window.scrollTo(0, 0);
}

// ---------- rutas ----------

async function route() {
  if (!token) return renderLogin();
  logoutEl.hidden = false;
  const parts = location.hash.replace(/^#\/?/, "").split("/").filter(Boolean);
  try {
    if (parts.length === 0) return await renderList();
    if (parts[0] === "w" && parts.length === 2) return await renderWorkout(parts[1]);
    crumbs({ text: "Mis carreras", href: "#/" });
    render(h("div", { class: "panel empty" }, "No encontrado."));
  } catch (e) {
    if (e instanceof AuthError) return logout(e.message);
    render(h("div", { class: "panel pad error" }, `Error: ${e.message}`));
  }
}

window.addEventListener("hashchange", route);
route();
