import { fechaValida } from "./indicadoresFormato.js";

const numeroValido = (valor) =>
  (typeof valor === "number" || (typeof valor === "string" && valor.trim() !== "")) && Number.isFinite(Number(valor)) && Number(valor) >= 0;
export function validarRespuestaIndicadores(data, consulta) {
  const fallo = () => {
    throw new Error("La información de indicadores está incompleta o tiene un formato inválido. Reintentá la consulta.");
  };
  if (
    !data ||
    !Array.isArray(data.tareas) ||
    !Array.isArray(data.dias) ||
    !Array.isArray(data.catalogo) ||
    data.desde !== consulta.desde ||
    data.hasta !== consulta.hasta
  )
    fallo();
  const cantidadDias = (Date.parse(consulta.hasta) - Date.parse(consulta.desde)) / 86400000 + 1;
  if (data.dias.length !== cantidadDias) fallo();
  const dias = new Set();
  for (const d of data.dias) {
    if (!fechaValida(d.dia) || d.dia < consulta.desde || d.dia > consulta.hasta || dias.has(d.dia)) fallo();
    dias.add(d.dia);
    for (const k of [
      "tareas",
      "piezas",
      "ok",
      "scrap",
      "real",
      "pausas",
      "pausa_seg",
      "ordenes",
      "mantenimientos",
      "mantenimiento_seg",
      "correctivo_seg",
    ]) {
      if (!numeroValido(d[k])) fallo();
    }
  }
  const ids = new Set();
  for (const t of data.tareas) {
    if (
      typeof t.id !== "string" ||
      !t.id ||
      ids.has(t.id) ||
      !dias.has(t.dia) ||
      typeof t.pedido_id !== "string" ||
      typeof t.articulo_id !== "string" ||
      !["inyectado", "rebabado", "armado", "embolsado"].includes(t.actividad) ||
      ![true, false, null].includes(t.es_ultimo)
    )
      fallo();
    ids.add(t.id);
    for (const k of ["piezas_ok", "piezas_scrap", "real_seg"]) if (!numeroValido(t[k])) fallo();
    for (const k of ["std_seg", "estandar"]) if (t[k] != null && !numeroValido(t[k])) fallo();
  }
  const articulos = new Set();
  for (const a of data.catalogo) {
    if (
      typeof a.id !== "string" ||
      !a.id ||
      articulos.has(a.id) ||
      typeof a.codigo !== "string" ||
      typeof a.nombre !== "string" ||
      (a.categoria != null && typeof a.categoria !== "string")
    )
      fallo();
    articulos.add(a.id);
  }
  return data;
}
