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
import { exigirSesion, json } from "../lib/sesion.js";

export const handler = async (event) => {
  if (event.httpMethod !== "POST")
    return json(405, { error: "Método no permitido" });
  if (Buffer.byteLength(event.body || "", "utf8") > 16384)
    return json(413, { error: "Solicitud demasiado grande" });
  const acceso = await exigirSesion(event, ["admin"]);
  if (acceso.response) return acceso.response;
  const { admin } = acceso;
  // 3) Validar los datos recibidos
  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return json(400, { error: "Datos inválidos" });
  }

  if (!body || typeof body !== "object" || Array.isArray(body))
    return json(400, { error: "Datos inválidos" });
  const email =
    typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const nombre = typeof body.nombre === "string" ? body.nombre.trim() : "";
  const rol = body.rol || "operario";

  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
    return json(400, { error: "E-mail inválido" });
  if (password.length < 12 || password.length > 128)
    return json(400, {
      error: "La contraseña debe tener entre 12 y 128 caracteres",
    });
  if (!["operario", "supervisor", "admin"].includes(rol))
    return json(400, { error: "Rol inválido" });

  if (nombre.length > 120)
    return json(400, { error: "El nombre admite hasta 120 caracteres" });

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
      error: dup
        ? "Ya existe un usuario con ese e-mail"
        : "No se pudo crear la cuenta. Revisá los datos y la política de contraseñas.",
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
