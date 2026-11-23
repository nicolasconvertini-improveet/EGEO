import { norm, estadoLabel } from "./format.js";
import { fechaValida } from "./indicadoresFormato.js";

export const ESTADOS_ORDENES = [
  "pendiente",
  "en_curso",
  "finalizado",
  "finalizado_pendientes",
  "cancelado",
];
export const estadosIniciales = (prefiltro) =>
  prefiltro?.estado && ESTADOS_ORDENES.includes(prefiltro.estado)
    ? [prefiltro.estado]
    : ESTADOS_ORDENES.filter((e) => e !== "cancelado");
const fechaArgentina = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/Argentina/Buenos_Aires",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
export function diaFinalizacion(valor) {
  if (!valor) return "";
  const fecha = new Date(valor);
  return Number.isFinite(fecha.getTime()) ? fechaArgentina.format(fecha) : "";
}
export function errorFechasOrdenes(desde, hasta) {
  if ((desde && !fechaValida(desde)) || (hasta && !fechaValida(hasta)))
    return "Ingresá fechas válidas.";
  return desde && hasta && desde > hasta
    ? "La fecha desde no puede ser posterior a la fecha hasta."
    : "";
}
export function filtrarOrdenes(
  pedidos,
  { estados, proceso = "", desde = "", hasta = "", q = "" },
) {
  if (errorFechasOrdenes(desde, hasta)) return [];
  const nq = norm(q.trim());
  return pedidos.filter((p) => {
    if (!estados.includes(p.estado)) return false;
    if (proceso && (p.proceso || "historica") !== proceso) return false;
    if (desde || hasta) {
      const dia = diaFinalizacion(p.finalizadoEn);
      if (!dia || (desde && dia < desde) || (hasta && dia > hasta))
        return false;
    }
    return (
      !nq ||
      [
        p.codigo,
        p.articuloNombre,
        p.articuloCodigo,
        estadoLabel(p.estado),
      ].some((valor) => norm(valor).includes(nq))
    );
  });
}
