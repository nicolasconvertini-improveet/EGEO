import { createClient } from "@supabase/supabase-js";

const json = (statusCode, body) => ({
  statusCode,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  body: JSON.stringify(body),
});

export const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "Método no permitido" });
  const token = /^Bearer\s+(.+)$/i.exec(event.headers?.authorization || event.headers?.Authorization || "")?.[1];
  if (!token) return json(401, { error: "Falta la sesión" });
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return json(500, { error: "Faltan variables de entorno en el servidor" });

  try {
    const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data, error } = await admin.auth.getUser(token);
    if (error || !data?.user) return json(401, { error: "Sesión inválida. Volvé a ingresar." });
    const { data: perfil, error: perfilError } = await admin.from("perfiles").select("rol, activo").eq("id", data.user.id).single();
    if (perfilError || perfil?.rol !== "admin" || perfil.activo !== true)
      return json(403, { error: "Sólo un administrador activo puede cambiar contraseñas" });

    let body;
    try {
      body = JSON.parse(event.body || "{}");
    } catch {
      return json(400, { error: "Datos inválidos" });
    }
    const { usuarioId, password } = body || {};
    if (typeof usuarioId !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(usuarioId))
      return json(400, { error: "Usuario inválido" });
    if (usuarioId === data.user.id) return json(400, { error: "Esta opción permite cambiar la contraseña de otros usuarios" });
    if (typeof password !== "string" || password.length < 6 || password.length > 128)
      return json(400, { error: "La contraseña debe tener entre 6 y 128 caracteres" });

    const { data: destino, error: destinoError } = await admin.from("perfiles").select("id").eq("id", usuarioId).maybeSingle();
    if (destinoError) return json(500, { error: "No se pudo verificar el usuario" });
    if (!destino) return json(404, { error: "El usuario ya no existe" });
    // Se permiten todos los roles de destino, incluidos otros administradores.
    const { error: updateError } = await admin.auth.admin.updateUserById(usuarioId, { password });
    if (updateError) {
      if (updateError.code === "weak_password")
        return json(400, {
          error: "La contraseña no cumple la política de seguridad. Elegí una más larga con letras, números y símbolos.",
        });
      if (updateError.code === "same_password") return json(400, { error: "Elegí una contraseña distinta de la actual" });
      return json(502, { error: "No se pudo cambiar la contraseña. Intentá nuevamente." });
    }
    return json(200, { ok: true });
  } catch {
    return json(500, { error: "No se pudo cambiar la contraseña. Intentá nuevamente." });
  }
};
