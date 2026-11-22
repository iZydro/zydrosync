// Panel de administración de ZydroSync. Sin dependencias salvo Leaflet (servido localmente).
// Todo el contenido dinámico se inserta como texto (textContent), nunca como HTML.
import { h, setCrumbs, fmtDateTime, fmtDate, fmtKm, fmtInt, fmtDuration, fmtPace, paceOf, fmtBytes, fmtAgo, downloadJson, loginForm } from "/shared/ui.js";
import { workoutView } from "/shared/workout-view.js";

const TOKEN_KEY = "zydrosync.adminToken";
const appEl = document.getElementById("app");
const crumbsEl = document.getElementById("crumbs");
const logoutEl = document.getElementById("logout");
let token = sessionStorage.getItem(TOKEN_KEY);
let usersCache = null;
let current = null; // vista con recursos que liberar (el mapa)

function render(...nodes) {
  current?.destroy();
  current = null;
  appEl.replaceChildren(...nodes);
}

const crumbs = (...items) => setCrumbs(crumbsEl, items);

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

const postJson = (path, body) =>
  api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

/** Fila de formulario: campos + botón, con el error de la API debajo. */
function inlineForm(fields, label, onSubmit) {
  const error = h("div", { class: "error" });
  const button = h("button", { class: "primary" }, label);
  const submit = async () => {
    error.textContent = "";
    button.disabled = true;
    try { await onSubmit(); } catch (e) { if (e.message !== "auth") error.textContent = e.message; } finally { button.disabled = false; }
  };
  button.addEventListener("click", submit);
  for (const f of fields) if (f.tagName === "INPUT") f.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });
  return h("div", { class: "panel pad" }, h("div", { class: "form-row" }, fields, button), error);
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
  render(loginForm({
    title: "Acceso de administración",
    intro: "Pega un token de tipo admin. Se crea con la CLI del servidor:",
    command: "tokens create <email> admin",
    placeholder: "zsa_…",
    message,
    onSubmit(value) {
      token = value;
      sessionStorage.setItem(TOKEN_KEY, token);
      location.hash = "#/users";
      route();
    },
  }));
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
  const email = h("input", { type: "email", placeholder: "email del usuario nuevo", autocomplete: "off" });
  const newUser = inlineForm([email], "Crear usuario", async () => {
    const created = await postJson("/users", { email: email.value });
    usersCache = null;
    location.hash = `#/users/${created.id}`;
  });

  render(
    h("h1", {}, "Usuarios"),
    h("div", { class: "subtitle" }, `${users.length} usuarios · ${totalWorkouts} entrenamientos`),
    newUser,
    h("div", { class: "panel table-wrap", style: "margin-top:12px" }, users.length === 0
      ? h("div", { class: "empty" }, "Sin usuarios.")
      : h("table", {},
        h("thead", {}, h("tr", {}, ["Email", "Alta", "Entrenos", "Último", "Datos", "Tokens activos"]
          .map((t, i) => h("th", { class: i >= 2 && i !== 3 ? "num" : "" }, t)))),
        h("tbody", {}, rows))),
  );
}

/** Recuadro con el secreto recién creado: solo existe en esta vista, no se vuelve a mostrar. */
function secretBox(created) {
  const copy = h("button", {}, "Copiar");
  copy.addEventListener("click", async () => {
    await navigator.clipboard.writeText(created.secret);
    copy.textContent = "Copiado";
  });
  return h("div", { class: "panel pad secret" },
    h("strong", {}, `Token ${created.token.kind} «${created.token.name}» creado. Cópialo ahora: no se volverá a mostrar.`),
    h("div", { class: "form-row" }, h("code", { class: "mono" }, created.secret), copy));
}

async function renderUser(userId, created) {
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

  const kind = h("select", {},
    [["device", "device · app iOS"], ["web", "web · Mis carreras (solo lectura)"],
      ["integration", "integration · importador (solo lectura)"], ["admin", "admin · este panel"]]
      .map(([value, text]) => h("option", { value }, text)));
  const name = h("input", { type: "text", placeholder: "nombre (p. ej. iPhone, navegador)", maxlength: 100 });
  const newToken = inlineForm([kind, name], "Crear token", async () => {
    if (kind.value === "admin" && !confirm("Un token admin ve y borra los datos de TODOS los usuarios. ¿Crearlo?")) return;
    const result = await postJson(`/users/${userId}/tokens`, { kind: kind.value, name: name.value });
    usersCache = null;
    await renderUser(userId, result);
  });

  const workoutRows = workouts.map((w) => h("tr", { class: "link", onclick: () => (location.hash = `#/users/${userId}/workouts/${w.workoutId}`) },
    h("td", {}, fmtDateTime(w.startDate)),
    h("td", {}, w.sport + (w.indoor ? " (cinta)" : "")),
    h("td", { class: "num" }, fmtKm(w.distanceM)),
    h("td", { class: "num" }, fmtDuration(w.durationSec)),
    h("td", { class: "num" }, fmtPace(paceOf(w.durationSec, w.distanceM))),
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
    created ? secretBox(created) : null,
    newToken,
    h("div", { class: "panel table-wrap", style: "margin-top:12px" }, h("table", {},
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

  const view = workoutView(w, {
    subtitle: `${w.sport}${w.indoor ? " en cinta" : ""} · ${user.email}`,
    actions: [
      h("button", { onclick: () => downloadJson(w) }, "Descargar JSON"),
      h("button", {
        class: "danger",
        onclick: async () => {
          if (!confirm("¿Borrar este entrenamiento del servidor? No se puede deshacer. (La app puede volver a enviarlo con «Borrar enviadas y volver a enviar».)")) return;
          await api(`/users/${userId}/workouts/${workoutId}`, { method: "DELETE" });
          usersCache = null;
          location.hash = `#/users/${userId}`;
        },
      }, "Borrar del servidor"),
    ],
  });
  render(view.node);
  current = view;
  view.mount();
}

function renderNotFound() {
  crumbs({ text: "Usuarios", href: "#/users" });
  render(h("div", { class: "panel empty" }, "No encontrado."));
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
