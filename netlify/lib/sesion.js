import { createClient } from "@supabase/supabase-js";

export const json = (statusCode, body) => ({
  statusCode,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  body: JSON.stringify(body),
});

// Toda nueva función interna debe pasar por este control antes de usar admin.
// El rol se consulta en la base; no se acepta un rol enviado por el navegador.
export async function exigirSesion(event, roles = ["admin"]) {
  const token = /^Bearer\s+(\S+)$/i.exec(event.headers?.authorization || event.headers?.Authorization || "")?.[1];
  if (!token) return { response: json(401, { error: "Falta la sesión" }) };
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return { response: json(500, { error: "Falta configurar el servidor" }) };
  try {
    const auth = { autoRefreshToken: false, persistSession: false };
    const admin = createClient(url, key, { auth });
    const { data, error } = await admin.auth.getUser(token);
    if (error || !data?.user) return { response: json(401, { error: "Sesión inválida. Volvé a ingresar." }) };
    // El JWT del usuario (no service_role) es el que ejecuta validar_sesion.
    const caller = createClient(url, key, { auth, global: { headers: { Authorization: `Bearer ${token}` } } });
    const { data: perfil, error: sessionError } = await caller.rpc("validar_sesion");
    if (sessionError)
      return {
        response: json(sessionError.code === "42501" ? 401 : 503, {
          error:
            sessionError.code === "42501"
              ? "Sesión cerrada o cuenta inactiva. Volvé a ingresar."
              : "No se pudo verificar la sesión. Intentá nuevamente.",
        }),
      };
    if (!perfil?.activo || perfil.id !== data.user.id || !roles.includes(perfil.rol))
      return { response: json(403, { error: "No tenés permisos para esta operación" }) };
    return { admin, user: data.user, perfil };
  } catch {
    return { response: json(503, { error: "No se pudo verificar la sesión. Intentá nuevamente." }) };
  }
}
