import { supabase } from "../supabaseClient";
export async function rpc(nombre, params = {}) {
  const { data, error } = await supabase.rpc(nombre, params);
  if (error) throw error;
  return data;
}
export async function filas(tabla) {
  const all = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await supabase
      .from(tabla)
      .select("*")
      .order("id")
      .range(offset, offset + 999);
    if (error) throw error;
    all.push(...data);
    if (data.length < 1000) return all;
  }
}
export async function catalogos() {
  const [maquinas, equipos, moldes, relaciones] = await Promise.all([
    filas("maquinas"),
    filas("equipos"),
    filas("moldes"),
    (async () => {
      const all = [];
      for (let offset = 0; ; offset += 1000) {
        const { data, error } = await supabase
          .from("molde_articulos")
          .select("*")
          .order("molde_id")
          .order("articulo_id")
          .range(offset, offset + 999);
        if (error) throw error;
        all.push(...data);
        if (data.length < 1000) return all;
      }
    })(),
  ]);
  return {
    maquinas,
    equipos,
    moldes: moldes.map((m) => ({
      ...m,
      articulos: relaciones.filter((r) => r.molde_id === m.id),
    })),
  };
}
export async function guardarActivo(tabla, form) {
  const { id, ...row } = form;
  const { error } = await (id
    ? supabase.from(tabla).update(row).eq("id", id)
    : supabase.from(tabla).insert(row));
  if (error) throw error;
}
export const solicitudes = () => filas("solicitudes_trabajo");
export const gestionarSolicitud = (accion, id, datos = {}, revision = null) =>
  rpc("gestionar_solicitud", {
    p_accion: accion,
    p_id: id,
    p_datos: datos,
    p_revision: revision,
  });
