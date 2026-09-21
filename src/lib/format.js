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

export function effColor(e) {
  if (e == null) return "var(--ink2)";
  if (e >= 95) return "var(--good)";
  if (e >= 80) return "var(--warn)";
  return "var(--bad)";
}

export const estadoLabel = (e) => ({ pendiente: "Pendiente", en_curso: "En curso", finalizado: "Finalizada" })[e] || e;

export const estadoBadge = (e) => ({ pendiente: "b-pend", en_curso: "b-curso", finalizado: "b-fin" })[e] || "b-pend";

export const findArt = (arts, id) => arts.find((a) => a.id === id);

export const findPed = (peds, id) => peds.find((p) => p.id === id);

export const norm = (s) =>
  (s || "")
    .toString()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
