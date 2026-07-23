/**
 * Alta de usuarios — se ejecuta en el servidor de Netlify.
 *
 * La clave service_role NUNCA llega al navegador: vive sólo como variable
 * de entorno de Netlify. Antes de crear nada, la función verifica que quien
 * llama sea un administrador con perfil activo.
 *
 * Variables de entorno necesarias en Netlify:
 *   SUPABASE_URL
 *   SUPABASE_SERVICE_ROLE_KEY
 */
import { createClient } from "@supabase/supabase-js";

const json = (status, body) => ({
  statusCode: status,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

export const handler = async (event) => {
  if (event.httpMethod !== "POST")
    return json(405, { error: "Método no permitido" });

  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey)
    return json(500, { error: "Faltan variables de entorno en el servidor" });

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1) Identificar a quien llama a partir de su token
  const token = (event.headers.authorization || "")
    .replace("Bearer ", "")
    .trim();
  if (!token) return json(401, { error: "Falta la sesión" });

  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user)
    return json(401, { error: "Sesión inválida" });

  // 2) Verificar que sea administrador activo
  const { data: perfil, error: perfilErr } = await admin
    .from("perfiles")
    .select("rol, activo")
    .eq("id", userData.user.id)
    .single();
  if (perfilErr || !perfil || perfil.rol !== "admin" || !perfil.activo)
    return json(403, { error: "Sólo un administrador puede crear usuarios" });

  // 3) Validar los datos recibidos
  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { error: "Datos inválidos" });
  }

  const email = (body.email || "").trim().toLowerCase();
  const password = body.password || "";
  const nombre = (body.nombre || "").trim();
  const rol = body.rol || "operario";

  if (!email || !email.includes("@"))
    return json(400, { error: "E-mail inválido" });
  if (password.length < 6)
    return json(400, {
      error: "La contraseña debe tener al menos 6 caracteres",
    });
  if (!["operario", "supervisor", "admin"].includes(rol))
    return json(400, { error: "Rol inválido" });

  // 4) Crear el usuario (ya confirmado, para uso interno)
  const { data: creado, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { nombre },
  });
  if (createErr) {
    const dup = /already|registered|exists/i.test(createErr.message || "");
    return json(dup ? 409 : 400, {
      error: dup ? "Ya existe un usuario con ese e-mail" : createErr.message,
    });
  }

  // 5) Completar el perfil (el disparador lo creó como operario)
  const { error: updErr } = await admin
    .from("perfiles")
    .update({ nombre: nombre || email.split("@")[0], rol, activo: true })
    .eq("id", creado.user.id);
  if (updErr)
    return json(500, {
      error: "Usuario creado, pero no se pudo asignar el rol",
    });

  return json(200, { ok: true, id: creado.user.id });
};
