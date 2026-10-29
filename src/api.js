import { supabase } from "./supabaseClient";

/* ---------- Perfil / rol ---------- */
export async function fetchPerfil(userId) {
  const { data, error } = await supabase.rpc("validar_sesion");
  if (error) throw error;
  if (data?.id !== userId)
    throw new Error("La sesión cambió. Volvé a ingresar.");
  return data; // { id, nombre, rol, activo }
}

/* ---------- Artículos ---------- */
function mapArticulo(r) {
  return {
    id: r.id,
    codigo: r.codigo,
    nombre: r.nombre,
    molde: r.molde,
    maquina: r.maquina,
    bocas: r.bocas,
    material: r.material,
    categoria: r.categoria,
    activo: r.activo,
    std: {
      inyectado: Number(r.std_inyectado) || 0,
      rebabado: Number(r.std_rebabado) || 0,
      armado: Number(r.std_armado) || 0,
      embolsado: Number(r.std_embolsado) || 0,
    },
  };
}

export async function fetchArticulos() {
  const { data, error } = await supabase
    .from("articulos")
    .select("*")
    .order("nombre", { ascending: true });
  if (error) throw error;
  return data.map(mapArticulo);
}

export async function saveArticulo(a, id) {
  const row = {
    codigo: a.codigo.trim(),
    nombre: a.nombre.trim(),
    molde: a.molde || null,
    maquina: a.maquina || null,
    bocas: Number(a.bocas) || null,
    material: a.material || null,
    categoria: a.categoria || null,
    activo: a.activo,
    std_inyectado: Number(a.std.inyectado) || 0,
    std_rebabado: Number(a.std.rebabado) || 0,
    std_armado: Number(a.std.armado) || 0,
    std_embolsado: Number(a.std.embolsado) || 0,
  };
  const q = id
    ? supabase.from("articulos").update(row).eq("id", id)
    : supabase.from("articulos").insert(row);
  const { error } = await q;
  if (error) throw error;
}

export async function setArticuloActivo(id, activo) {
  const { error } = await supabase
    .from("articulos")
    .update({ activo })
    .eq("id", id);
  if (error) throw error;
}

/* ---------- Pedidos ---------- */
export async function fetchPedidos() {
  const { data, error } = await supabase
    .from("v_pedidos")
    .select("*")
    .order("creado", { ascending: false });
  if (error) throw error;
  return data.map((p) => ({
    id: p.id,
    codigo: p.codigo,
    articuloId: p.articulo_id,
    proceso: p.proceso,
    moldeId: p.molde_id,
    configuracion: p.configuracion,
    articulos: p.articulos || [],
    articuloNombre: p.articulo_nombre,
    articuloCodigo: p.articulo_codigo,
    cantidad: p.cantidad,
    estado: p.estado,
    estadoRevision: p.estado_revision,
    okAcum: p.ok_acum, // piezas completas (etapa más atrasada)
    okBruto: p.ok_bruto, // volumen total trabajado
    etapasReq: p.etapas_req,
    etapasCompletas: p.etapas_completas,
    scrapAcum: p.scrap_acum,
  }));
}

export async function consultarEstadoPedido(id) {
  const { data, error } = await supabase
    .from("pedidos")
    .select("id, estado, estado_revision")
    .eq("id", id)
    .single();
  if (error) throw error;
  return data;
}

export async function fetchHistorialEstado(id, limite = 20) {
  const registros = [];
  let count = 0;
  // Páginas pequeñas: permite consultar el historial más allá del límite
  // de filas por respuesta de Supabase, sin truncarlo silenciosamente.
  while (registros.length < limite) {
    const {
      data,
      count: total,
      error,
    } = await supabase
      .from("pedido_estado_historial")
      .select("*", { count: "exact" })
      .eq("pedido_id", id)
      .order("creado", { ascending: false })
      .order("id", { ascending: false })
      .range(registros.length, Math.min(registros.length + 99, limite - 1));
    if (error) throw error;
    count = total;
    registros.push(...data);
    if (!data.length || registros.length >= count) break;
  }
  return { data: registros, count };
}

export async function cambiarEstadoPedido({
  id,
  pedidoId,
  revision,
  accion,
  motivo,
}) {
  const { data, error } = await supabase.rpc("cambiar_estado_pedido", {
    p_solicitud: id,
    p_pedido: pedidoId,
    p_revision: revision,
    p_accion: accion,
    p_motivo: motivo,
  });
  if (error) throw error;
  return data;
}

export async function createPedido({
  codigo,
  articuloId,
  moldeId,
  proceso,
  cantidad,
}) {
  const { error } = await supabase.from("pedidos").insert({
    codigo: codigo.trim(),
    articulo_id: proceso === "inyectado" ? null : articuloId,
    proceso,
    molde_id: proceso === "inyectado" ? moldeId : null,
    cantidad: Number(cantidad),
  });
  if (error) throw error;
}

/* Cambia la cantidad a fabricar. La base valida: > 0 y no menor a lo ya
   fabricado en los procesos que aplican al artículo. Recalcula el estado. */
export async function editarCantidadPedido(pedidoId, cantidad) {
  const { data, error } = await supabase.rpc("editar_cantidad_pedido", {
    p_pedido: pedidoId,
    p_cantidad: Number(cantidad),
  });
  if (error) {
    if (error.code === "PGRST202")
      throw new Error("Falta aplicar la migración 15 en Supabase.");
    throw new Error(error.message || "No se pudo cambiar la cantidad");
  }
  return data; // { id, cantidad, estado, minimo }
}

/* ---------- Usuarios (sólo administradores) ---------- */
export async function fetchUsuarios() {
  const { data, error } = await supabase
    .from("perfiles")
    .select("*")
    .order("nombre", { ascending: true });
  if (error) throw error;
  return data;
}

export async function updateUsuario(id, cambios) {
  const { error } = await supabase
    .from("perfiles")
    .update(cambios)
    .eq("id", id);
  if (error) throw error;
}

/* El alta pasa por una función del servidor: la clave con permisos
   de administración nunca llega al navegador. */
export async function crearUsuario({ email, password, nombre, rol }) {
  const { data } = await supabase.auth.getSession();
  const token = data?.session?.access_token;
  if (!token) throw new Error("Sesión vencida. Volvé a ingresar.");

  const res = await fetch("/.netlify/functions/crear-usuario", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ email, password, nombre, rol }),
  });

  let payload = null;
  try {
    payload = await res.json();
  } catch {
    /* respuesta no JSON */
  }

  if (!res.ok) {
    if (res.status === 404)
      throw new Error(
        "No se encontró el servidor de usuarios. Para desarrollo usá npm run dev.",
      );
    throw new Error(payload?.error || "No se pudo crear el usuario");
  }
  return payload;
}

export async function consultarEmailUsuario(usuarioId) {
  const { data } = await supabase.auth.getSession();
  const token = data?.session?.access_token;

  if (!token) {
    throw new Error("Sesión vencida. Volvé a ingresar.");
  }

  const res = await fetch("/.netlify/functions/cambiar-password", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      usuarioId,
      accion: "consultar-email",
    }),
  });

  let payload;
  try {
    payload = await res.json();
  } catch {
    // La función puede no estar publicada todavía.
  }

  if (!res.ok || payload?.ok !== true || !payload?.email) {
    throw new Error(
      payload?.error || "No se pudo consultar el correo del usuario.",
    );
  }

  return payload.email;
}

export async function cambiarPasswordUsuario(usuarioId, password) {
  const { data } = await supabase.auth.getSession();
  const token = data?.session?.access_token;
  if (!token) throw new Error("Sesión vencida. Volvé a ingresar.");
  const res = await fetch("/.netlify/functions/cambiar-password", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ usuarioId, password }),
  });
  let payload;
  try {
    payload = await res.json();
  } catch {
    /* Netlify no disponible */
  }
  if (!res.ok || payload?.ok !== true)
    throw new Error(
      payload?.error ||
        "No se pudo cambiar la contraseña. Verificá que el sitio tenga publicada la función de cambio de contraseña.",
    );
}

/* ---------- Tareas ---------- */
function mapTarea(t) {
  return {
    id: t.id,
    moldeId: t.molde_id,
    proceso: t.proceso,
    resultados: t.resultados || [],
    ciclos: t.ciclos == null ? null : Number(t.ciclos),
    segundosCiclo: t.segundos_ciclo == null ? null : Number(t.segundos_ciclo),
    pedidoId: t.pedido_id,
    pedidoCodigo: t.pedido_codigo,
    articuloId: t.articulo_id,
    articuloNombre: t.articulo_nombre,
    actividad: t.actividad,
    operario: t.operario_nombre,
    operarioId: t.operario_id,
    inicio: t.inicio,
    fin: t.fin,
    ok: t.piezas_ok,
    scrap: t.piezas_scrap,
    realSec: t.real_seg,
    stdSec: Number(t.std_seg) || 0,
    confirmada: t.confirmada,
    observaciones: t.observaciones || "",
    revision: t.revision,
    totalSec: t.total_seg,
    pausaSec: t.pausa_seg,
    pausaId: t.pausa_id,
    pausaInicio: t.pausa_inicio,
    pausaMotivo: t.pausa_motivo,
    servidorAhora: t.servidor_ahora,
    recibidoEn: Date.now(),
  };
}

/* desde/hasta: ISO, rango [desde, hasta) sobre la hora de fin.
   operarioId: si viene, sólo las tareas de ese usuario (rol operario). */
export async function fetchTareas({
  desdeDias = null,
  desde = null,
  hasta = null,
  operarioId = null,
  limit = 500,
} = {}) {
  let q = supabase
    .from("v_tareas")
    .select("*")
    .eq("confirmada", true)
    .order("fin", { ascending: false });
  if (desdeDias != null) {
    const d = new Date();
    d.setDate(d.getDate() - desdeDias);
    q = q.gte("fin", d.toISOString());
  }
  if (desde) q = q.gte("fin", desde);
  if (hasta) q = q.lt("fin", hasta);
  if (operarioId) q = q.eq("operario_id", operarioId);
  q = q.limit(limit);
  const { data, error } = await q;
  if (error) throw error;
  return data.map(mapTarea);
}

/* Totales por etapa de un pedido (las 4 actividades, en cero si no hubo) */
export async function fetchEtapasPedido(pedidoId) {
  const { data, error } = await supabase
    .from("v_pedido_etapas")
    .select("*")
    .eq("pedido_id", pedidoId);
  if (error) throw error;
  return data;
}

/* Cantidad de tareas actualmente abiertas (sin finalizar) */
export async function contarTareasEnCurso() {
  const { count, error } = await supabase
    .from("tareas")
    .select("id", { count: "exact", head: true })
    .is("fin", null);
  if (error) throw error;
  return count || 0;
}

/* ---------- Flujo de la tarea del operario ---------- */

/* Tarea propia sin confirmar: abierta (fin null) o pendiente de cargar piezas */
export async function fetchTareaActiva() {
  const { data: userData } = await supabase.auth.getUser();
  const uid = userData?.user?.id;
  if (!uid) return null;
  const { data, error } = await supabase
    .from("v_tareas")
    .select("*")
    .eq("operario_id", uid)
    .eq("confirmada", false)
    .order("inicio", { ascending: false })
    .limit(1);
  if (error) throw error;
  return data && data.length ? mapTarea(data[0]) : null;
}

async function gestionarTarea(p_accion, params = {}) {
  const { data, error } = await supabase.rpc("gestionar_tarea", {
    p_accion,
    ...params,
  });
  if (error) throw error;
  return data;
}

export function iniciarTarea({ pedidoId, actividad }) {
  return gestionarTarea("iniciar", {
    p_pedido: pedidoId,
    p_actividad: actividad,
  });
}

export function pausarTarea(tarea, motivo) {
  return gestionarTarea("pausar", {
    p_tarea: tarea.id,
    p_revision: tarea.revision,
    p_motivo: motivo,
  });
}

export function reanudarTarea(tarea) {
  return gestionarTarea("reanudar", {
    p_tarea: tarea.id,
    p_revision: tarea.revision,
  });
}

export function finalizarTarea(tarea) {
  return gestionarTarea("finalizar", {
    p_tarea: tarea.id,
    p_revision: tarea.revision,
  });
}

export async function confirmarTarea(
  tarea,
  { ok, scrap, observaciones, resultados },
) {
  if (tarea.moldeId) {
    const { data, error } = await supabase.rpc("confirmar_tarea_molde", {
      p_tarea: tarea.id,
      p_revision: tarea.revision,
      p_resultados: resultados,
      p_observaciones: observaciones,
    });
    if (error) throw error;
    return data;
  }
  return gestionarTarea("confirmar", {
    p_tarea: tarea.id,
    p_revision: tarea.revision,
    p_ok: ok,
    p_scrap: scrap,
    p_observaciones: observaciones,
  });
}

export async function fetchMotivosParada() {
  const { data, error } = await supabase
    .from("motivos_parada")
    .select("id,nombre,orden")
    .eq("activo", true)
    .order("orden", { ascending: true })
    .order("nombre", { ascending: true });
  if (error) throw error;
  return data || [];
}

/* ---------- Tareas en curso (abiertas o pendientes de confirmar) ---------- */
export async function fetchTareasAbiertas({ operarioId = null } = {}) {
  let q = supabase
    .from("v_tareas")
    .select("*")
    .eq("confirmada", false)
    .order("inicio", { ascending: false });
  if (operarioId) q = q.eq("operario_id", operarioId);
  const { data, error } = await q;
  if (error) throw error;
  return data.map(mapTarea);
}

/* ---------- Pausas ---------- */
/* Pausas iniciadas en el rango [desde, hasta), con el operario de la tarea. */
export async function fetchPausas({ desde, hasta }) {
  const { data, error } = await supabase
    .from("tarea_pausas")
    .select("id, tarea_id, motivo, inicio, fin, tareas!inner(operario_id)")
    .gte("inicio", desde)
    .lt("inicio", hasta);
  if (error) throw error;
  const ahora = Date.now();
  return (data || []).map((p) => ({
    id: p.id,
    tareaId: p.tarea_id,
    motivo: p.motivo,
    inicio: p.inicio,
    fin: p.fin,
    operarioId: p.tareas?.operario_id,
    seg: Math.max(
      0,
      ((p.fin ? new Date(p.fin).getTime() : ahora) -
        new Date(p.inicio).getTime()) /
        1000,
    ),
  }));
}

export async function fetchPausasTarea(tareaId) {
  const { data, error } = await supabase
    .from("tarea_pausas")
    .select("id, motivo, motivo_id, inicio, fin")
    .eq("tarea_id", tareaId)
    .order("inicio", { ascending: true });
  if (error) throw error;
  return data || [];
}

export async function fetchMotivosTodos() {
  const { data, error } = await supabase
    .from("motivos_parada")
    .select("id,nombre,activo")
    .order("orden")
    .order("nombre");
  if (error) throw error;
  return data || [];
}

/* ---------- Administración de tareas y pausas (sólo admin, migración 18) ---------- */
async function rpcAdmin(nombre, params) {
  const { data, error } = await supabase.rpc(nombre, params);
  if (error) {
    if (error.code === "PGRST202")
      throw new Error("Falta aplicar la migración 18 en Supabase.");
    throw new Error(error.message || "No se pudo guardar");
  }
  return data;
}

export const adminEditarTarea = (
  t,
  { inicio, fin, ok, scrap, observaciones, motivo, resultados },
) =>
  t.moldeId
    ? rpcAdmin("admin_editar_tarea_molde", {
        p_tarea: t.id,
        p_revision: t.revision,
        p_inicio: inicio,
        p_fin: fin,
        p_resultados: resultados,
        p_observaciones: observaciones,
        p_motivo: motivo,
      })
    : rpcAdmin("admin_editar_tarea", {
        p_tarea: t.id,
        p_revision: t.revision,
        p_inicio: inicio,
        p_fin: fin,
        p_ok: Number(ok),
        p_scrap: Number(scrap),
        p_observaciones: observaciones,
        p_motivo: motivo,
      });

export const adminEliminarTarea = (t, motivo) =>
  rpcAdmin("admin_eliminar_tarea", {
    p_tarea: t.id,
    p_revision: t.revision,
    p_motivo: motivo,
  });

export const adminEditarPausa = (pausaId, { inicio, fin, motivoId, motivo }) =>
  rpcAdmin("admin_editar_pausa", {
    p_pausa: pausaId,
    p_inicio: inicio,
    p_fin: fin,
    p_motivo_id: motivoId,
    p_motivo: motivo,
  });

export const adminEliminarPausa = (pausaId, motivo) =>
  rpcAdmin("admin_eliminar_pausa", { p_pausa: pausaId, p_motivo: motivo });
