import { supabase } from "../supabaseClient";

async function consultar(nombre, parametros = {}, signal) {
  let peticion = supabase.rpc(nombre, parametros);
  if (signal) peticion = peticion.abortSignal(signal);
  const { data, error } = await peticion;
  if (error) throw new Error(error.message);
  return data;
}

export async function cargarMantenimientos(signal) {
  const [datos, usuarios] = await Promise.all([
    consultar("exportar_mantenimientos", {}, signal),
    consultar("ejecutores_mantenimiento", {}, signal),
  ]);
  if (!Array.isArray(datos?.filas) || String(datos.filas.length) !== datos.total || !Array.isArray(usuarios))
    throw new Error("La información recibida está incompleta.");
  return { registros: datos.filas, usuarios };
}

export function guardarMantenimiento(id, formulario) {
  return consultar("registrar_mantenimiento", {
    p_id: id,
    p_ejecutor_id: formulario.ejecutor,
    p_fecha_ejecucion: formulario.fecha,
    p_detalle: formulario.detalle.trim(),
    p_preventivo: formulario.preventivo,
    p_minutos: Number(formulario.minutos),
  });
}
