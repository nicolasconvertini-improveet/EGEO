// Reglas compartidas de presentación y validación del módulo.
export const MAX_DIAS_INDICADORES = 93;
export const TAMANO_PAGINA_INDICADORES = 20;
const zona = "America/Argentina/Buenos_Aires";
const formatoFecha = new Intl.DateTimeFormat("en-CA", { timeZone: zona, year: "numeric", month: "2-digit", day: "2-digit" });
const formatos = [0, 1, 2].map((maximumFractionDigits) => new Intl.NumberFormat("es-AR", { maximumFractionDigits }));
export const fmt = (valor, decimales = 1) =>
  valor == null || !Number.isFinite(Number(valor)) ? "No aplica" : formatos[decimales].format(Number(valor));
export const horas = (valor) => (valor == null ? "No aplica" : fmt(Number(valor) / 3600, 2) + " h");
export const pct = (valor) => (valor == null ? "No aplica" : fmt(valor) + " %");
export const hoy = (fecha = new Date()) => formatoFecha.format(fecha);
export function rango(tipo, fecha = new Date()) {
  const hasta = hoy(fecha);
  const desde = new Date(hasta + "T12:00:00Z");
  if (tipo === "semana") desde.setUTCDate(desde.getUTCDate() - ((desde.getUTCDay() + 6) % 7));
  if (tipo === "mes") desde.setUTCDate(1);
  return { desde: desde.toISOString().slice(0, 10), hasta };
}
export function fechaValida(valor) {
  if (typeof valor !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(valor)) return false;
  const fecha = new Date(valor + "T00:00:00Z");
  return Number.isFinite(fecha.getTime()) && fecha.toISOString().slice(0, 10) === valor;
}
export function validarPeriodo(desde, hasta, limite = hoy()) {
  if (!fechaValida(desde) || !fechaValida(hasta)) return "Elegí fechas válidas.";
  const dias = (Date.parse(hasta) - Date.parse(desde)) / 86400000 + 1;
  return dias < 1 || dias > MAX_DIAS_INDICADORES || hasta > limite ? "Elegí un período de hasta 93 días, sin fechas futuras." : "";
}
