// Duraciones declaradas en minutos; el consumo se mantiene en gramos.
export const minutosValidos = (v) =>
  v !== null &&
  v !== undefined &&
  String(v).trim() !== "" &&
  Number.isFinite(Number(v)) &&
  Number(v) >= 0;
export const formatearKg = (gramos) =>
  new Intl.NumberFormat("es-AR", { maximumFractionDigits: 6 }).format(
    Number(gramos) / 1000,
  ) + " kg";
export const pendienteCierreMolde = (p) =>
  !!p?.requiereCierreMolde &&
  !!p.controlMolde &&
  !p.controlMolde.bajado_en &&
  ["pendiente", "en_curso"].includes(p.estado) &&
  Number(p.okAcum) >= Number(p.cantidad);
