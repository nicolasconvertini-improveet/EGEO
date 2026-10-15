import { supabase } from "../supabaseClient";
import { validarRespuestaIndicadores } from "./indicadoresContrato";

export async function cargarIndicadores(consulta, signal) {
  const { data, error } = await supabase
    .rpc("indicadores_egeo_v2", {
      p_desde: consulta.desde,
      p_hasta: consulta.hasta,
      // null = todos; [] = ninguno. No intercambiar estos dos significados.
      p_articulos: consulta.articulos,
      p_proceso: consulta.proceso,
      p_operario: consulta.operario || null, // null = todos los usuarios
    })
    .abortSignal(signal);
  if (error) {
    if (error.code === "PGRST202") throw new Error("Falta aplicar la migración 14 en Supabase para habilitar los indicadores.");
    if (error.code === "42501") throw new Error("Se requiere una sesión activa de administrador. Volvé a ingresar.");
    throw new Error(error.message || "No se pudieron cargar los indicadores.");
  }
  return validarRespuestaIndicadores(data, consulta);
}
