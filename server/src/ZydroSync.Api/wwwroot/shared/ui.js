// Utilidades comunes de la web «Mis carreras» y del panel de administración.
// Todo el contenido dinámico se inserta como texto (textContent), nunca como HTML.

export function h(tag, attrs, ...children) {
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

export function svg(tag, attrs, ...children) {
  const el = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  for (const c of children) el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return el;
}

/** Migas de pan: [{text, href?}, …]. */
export function setCrumbs(container, items) {
  container.replaceChildren(...items.flatMap((item, i) => [
    i > 0 ? h("span", { class: "sep" }, "›") : null,
    item.href ? h("a", { href: item.href }, item.text) : h("span", {}, item.text),
  ]).filter(Boolean));
}

// ---------- formato ----------

export const fmtDateTime = (iso) => new Date(iso).toLocaleString("es-ES", { dateStyle: "medium", timeStyle: "short" });
export const fmtDate = (iso) => new Date(iso).toLocaleDateString("es-ES", { dateStyle: "medium" });
export const fmtKm = (m) => (m == null ? "—" : (m / 1000).toLocaleString("es-ES", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
export const fmtInt = (n) => (n == null ? "—" : Math.round(n).toLocaleString("es-ES"));

export function fmtDuration(sec) {
  if (sec == null) return "—";
  const s = Math.round(sec), hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  return (hh ? `${hh}:${String(mm).padStart(2, "0")}` : `${mm}`) + `:${String(ss).padStart(2, "0")}`;
}

/** Horas totales para resúmenes largos: "37 h 12 min". */
export function fmtHours(sec) {
  const m = Math.round((sec || 0) / 60);
  return m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")} min` : `${m} min`;
}

export function fmtPace(secPerKm) {
  if (!secPerKm || !isFinite(secPerKm)) return "—";
  const s = Math.round(secPerKm);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export const paceOf = (durationSec, distanceM) => (distanceM ? durationSec / (distanceM / 1000) : null);

export function fmtBytes(b) {
  if (b == null) return "—";
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)} KB`;
  return `${(b / 1024 / 1024).toFixed(1)} MB`;
}

export function fmtAgo(iso) {
  if (!iso) return "nunca";
  const sec = (Date.now() - new Date(iso).getTime()) / 1000;
  if (sec < 90) return "hace un momento";
  if (sec < 3600) return `hace ${Math.round(sec / 60)} min`;
  if (sec < 86400) return `hace ${Math.round(sec / 3600)} h`;
  return `hace ${Math.round(sec / 86400)} d`;
}

export const mean = (a) => (a && a.length ? a.reduce((x, y) => x + y, 0) / a.length : null);

// ---------- descargas ----------

export function downloadJson(w) {
  const blob = new Blob([JSON.stringify(w, null, 2)], { type: "application/json" });
  const a = h("a", { href: URL.createObjectURL(blob), download: `zydrosync-${w.workoutId}.json` });
  document.body.append(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

// ---------- sesión con token ----------

/**
 * Pantalla de acceso con token. El token se guarda solo en esta pestaña (sessionStorage):
 * se borra al cerrarla y no lo ven otras pestañas ni sobrevive al navegador.
 */
export function loginForm({ title, intro, command, placeholder, message, onSubmit }) {
  const input = h("input", { type: "password", placeholder, autocomplete: "off", autofocus: true });
  const submit = () => {
    const value = input.value.trim();
    if (value) onSubmit(value);
  };
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });
  return h("div", { class: "login panel pad" },
    h("h1", {}, title),
    h("p", {}, intro),
    command ? h("p", { class: "mono" }, command) : null,
    input,
    h("div", { class: "actions", style: "margin-top:12px" }, h("button", { class: "primary", onclick: submit }, "Entrar")),
    h("p", { class: "muted", style: "font-size:12px" }, "Se guarda solo en esta pestaña y se borra al cerrarla."),
    message ? h("div", { class: "error" }, message) : null,
  );
}
