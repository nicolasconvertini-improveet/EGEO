import { createClient } from "@supabase/supabase-js";
import { estadoLocal } from "./local-config.mjs";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
const s = estadoLocal();
const archivo = ".local/usuarios-demo.json";
if (existsSync(archivo))
  throw new Error(
    "Las credenciales demo ya existen. No se cambian contraseñas automáticamente.",
  );
const api = createClient(s.API_URL, s.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const cuentas = [];
for (const rol of ["admin", "supervisor", "operario"]) {
  const email = `qa-${rol}-${crypto.randomUUID().slice(0, 8)}@egeo.test`,
    password = crypto.randomUUID() + "aA1!";
  const { data, error } = await api.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { nombre: "QA " + rol },
  });
  if (error) throw error;
  const { error: err } = await api
    .from("perfiles")
    .update({ rol })
    .eq("id", data.user.id);
  if (err) throw err;
  cuentas.push({ rol, email, password });
}
mkdirSync(".local", { recursive: true });
writeFileSync(archivo, JSON.stringify(cuentas, null, 2));
console.log(
  "Usuarios de prueba creados. Credenciales en .local/usuarios-demo.json (excluido de Git).",
);
