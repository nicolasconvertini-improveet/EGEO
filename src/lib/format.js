export const nf = (n) => (n ?? 0).toLocaleString("es-AR");

export const fmtClock = (sec) => {
  sec = Math.max(0, Math.round(sec || 0));
  const h = Math.floor(sec / 3600),
    m = Math.floor((sec % 3600) / 60),
    s = sec % 60;
  const p = (x) => String(x).padStart(2, "0");
  return h > 0 ? `${p(h)}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`;
};

export const fmtDT = (iso) => {
  if (!iso) return "—";
  const d = new Date(iso),
    p = (x) => String(x).padStart(2, "0");
  return `${p(d.getDate())}/${p(d.getMonth() + 1)} ${p(d.getHours())}:${p(d.getMinutes())}`;
};

export const fmtHora = (iso) => {
  if (!iso) return "—";
  const d = new Date(iso),
    p = (x) => String(x).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
};

export const isoDate = (d) => {
  const x = new Date(d);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
};

export const dayKey = (d) => {
  const x = new Date(d);
  return `${x.getFullYear()}-${x.getMonth()}-${x.getDate()}`;
};

export const dayShort = (d) => {
  const x = new Date(d);
  return `${String(x.getDate()).padStart(2, "0")}/${String(x.getMonth() + 1).padStart(2, "0")}`;
};

export function efficiency(art, actividad, ok, realSec) {
  if (!art || !ok || !realSec) return null;
  const std = art.std[actividad];
  if (!std) return null;
  return ((ok * std) / realSec) * 100;
}

/* Escala única de colores de productividad: la usan los gráficos y su leyenda. */
export const ESCALA_EFF = [
  { desde: 95, color: "var(--good)", label: "≥ 95 %", desc: "Cumple el estándar" },
  { desde: 80, color: "var(--warn)", label: "80 – 94 %", desc: "Por debajo del estándar" },
  { desde: -Infinity, color: "var(--bad)", label: "< 80 %", desc: "Crítico" },
];

export function effColor(e) {
  if (e == null) return "var(--ink2)";
  return ESCALA_EFF.find((x) => e >= x.desde).color;
}

/* Fecha/hora ISO <-> valor de <input type="datetime-local"> (hora local). */
export const toInputDT = (iso) => {
  if (!iso) return "";
  const d = new Date(iso),
    p = (x) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
};
export const fromInputDT = (v) => (v ? new Date(v).toISOString() : null);

/* Límites [desde, hasta) de un día local, en ISO, para consultar la base. */
export const limitesDia = (fechaISO, diasAtras = 0) => {
  const [y, m, d] = fechaISO.split("-").map(Number);
  return {
    desde: new Date(y, m - 1, d - diasAtras).toISOString(),
    hasta: new Date(y, m - 1, d + 1).toISOString(),
  };
};

export const fmtMin = (sec) => {
  const m = Math.round((sec || 0) / 60);
  return m >= 60 ? `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")} min` : `${m} min`;
};

export const estadoLabel = (e) =>
  ({
    pendiente: "Pendiente",
    en_curso: "En curso",
    finalizado: "Finalizada",
    cancelado: "Cancelada",
    finalizado_pendientes: "Finalizada con pendientes",
  })[e] || e;

export const estadoBadge = (e) =>
  ({ pendiente: "b-pend", en_curso: "b-curso", finalizado: "b-fin", cancelado: "b-off", finalizado_pendientes: "b-pendientes" })[e] ||
  "b-pend";

export const findArt = (arts, id) => arts.find((a) => a.id === id);

export const findPed = (peds, id) => peds.find((p) => p.id === id);

export const norm = (s) =>
  (s || "")
    .toString()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
