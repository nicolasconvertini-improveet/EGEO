import { supabase } from "./supabaseClient";

/* ---------- Perfil / rol ---------- */
export async function fetchPerfil(userId) {
  const { data, error } = await supabase
    .from("perfiles")
    .select("*")
    .eq("id", userId)
    .single();
  if (error) throw error;
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
    articuloNombre: p.articulo_nombre,
    articuloCodigo: p.articulo_codigo,
    cantidad: p.cantidad,
    estado: p.estado,
    okAcum: p.ok_acum,
    scrapAcum: p.scrap_acum,
  }));
}

export async function createPedido({ codigo, articuloId, cantidad }) {
  const { error } = await supabase
    .from("pedidos")
    .insert({
      codigo: codigo.trim(),
      articulo_id: articuloId,
      cantidad: Number(cantidad),
    });
  if (error) throw error;
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
        "El alta de usuarios sólo funciona en el sitio publicado.",
      );
    throw new Error(payload?.error || "No se pudo crear el usuario");
  }
  return payload;
}

/* ---------- Tareas ---------- */
function mapTarea(t) {
  return {
    id: t.id,
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
  };
}

export async function fetchTareas({ desdeDias = null, limit = 500 } = {}) {
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

export async function iniciarTarea({ pedidoId, actividad }) {
  const { data: userData } = await supabase.auth.getUser();
  const { data, error } = await supabase
    .from("tareas")
    .insert({
      pedido_id: pedidoId,
      actividad,
      inicio: new Date().toISOString(),
      operario_id: userData?.user?.id,
    })
    .select("id")
    .single();
  if (error) throw error;
  return data.id;
}

export async function finalizarTarea(tareaId) {
  const { error } = await supabase
    .from("tareas")
    .update({ fin: new Date().toISOString() })
    .eq("id", tareaId);
  if (error) throw error;
}

export async function confirmarTarea(tareaId, { ok, scrap }) {
  const { error } = await supabase
    .from("tareas")
    .update({ piezas_ok: ok, piezas_scrap: scrap, confirmada: true })
    .eq("id", tareaId);
  if (error) throw error;
}

export async function cancelarTarea(tareaId) {
  const { error } = await supabase.from("tareas").delete().eq("id", tareaId);
  if (error) throw error;
}
