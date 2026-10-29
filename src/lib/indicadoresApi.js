import { supabase } from "../supabaseClient";
import { validarRespuestaIndicadores } from "./indicadoresContrato";

export async function cargarIndicadores(consulta, signal) {
  const { data, error } = await supabase
    .rpc("indicadores_tablas", {
      p_desde: consulta.desde,
      p_hasta: consulta.hasta,
      // null = todos; [] = ninguno. No intercambiar estos dos significados.
      p_articulos: consulta.articulos,
      p_proceso: consulta.proceso,
      p_operario: consulta.operario || null, // null = todos los usuarios
    })
    .abortSignal(signal);
  if (error) {
    if (error.code === "PGRST202") throw new Error("Falta actualizar la base para habilitar los indicadores. En local ejecutá npm run db:migrate.");
    if (error.code === "42501") throw new Error("Se requiere una sesión activa de administrador. Volvé a ingresar.");
    throw new Error(error.message || "No se pudieron cargar los indicadores.");
  }
  if (!Array.isArray(data?.produccion) || !Array.isArray(data?.tiempos) || !Number.isFinite(Number(data?.total_segundos))) {
    throw new Error("La información de las tablas está incompleta. Reintentá la consulta.");
  }
  return validarRespuestaIndicadores(data, consulta);
}
