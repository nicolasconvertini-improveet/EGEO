import { createClient } from "@supabase/supabase-js";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { estadoLocal } from "./local-config.mjs";

const archivo = ".local/usuarios-demo.json";
const cuentas = [
  { email: "qa-admin@egeo.test", nombre: "Administrador QA", rol: "admin" },
  {
    email: "qa-supervisor@egeo.test",
    nombre: "Supervisor QA",
    rol: "supervisor",
  },
  { email: "qa-operario@egeo.test", nombre: "Operario QA", rol: "operario" },
  {
    email: "qa-operario2@egeo.test",
    nombre: "Segundo operario QA",
    rol: "operario",
  },
];
const opciones = { auth: { persistSession: false, autoRefreshToken: false } };
const must = async (peticion) => {
  const { data, error } = await peticion;
  if (error) throw new Error(error.message);
  return data;
};

async function main() {
  const args = process.argv.slice(2);
  if (args.some((a) => a !== "--reset-passwords"))
    throw new Error(
      "Solo se admite --reset-passwords. No se aceptan URLs ni claves externas.",
    );

  // Credenciales obtenidas del CLI local: nunca de .env ni de process.env.
  let local;
  try {
    local = estadoLocal();
  } catch {
    throw new Error("Iniciá Docker y ejecutá npm run db:start antes del seed.");
  }
  const url = new URL(local.API_URL);
  if (
    url.protocol !== "http:" ||
    url.hostname !== "127.0.0.1" ||
    url.port !== "54321" ||
    !local.SERVICE_ROLE_KEY ||
    !local.ANON_KEY
  )
    throw new Error(
      "El seed requiere Supabase Docker en http://127.0.0.1:54321.",
    );

  const admin = createClient(url.origin, local.SERVICE_ROLE_KEY, opciones);
  const existentes = [];
  for (let page = 1; ; page++) {
    const data = await must(
      admin.auth.admin.listUsers({ page, perPage: 1000 }),
    );
    existentes.push(...data.users);
    if (data.users.length < 1000) break;
  }

  const reiniciar = args.includes("--reset-passwords");
  const guardado = existsSync(archivo)
    ? JSON.parse(readFileSync(archivo, "utf8"))
    : null;
  if (
    guardado &&
    (guardado.version !== 1 ||
      guardado.url !== url.origin ||
      !Array.isArray(guardado.usuarios))
  )
    throw new Error(
      "El archivo de credenciales no corresponde a esta instancia local. Revisalo antes de continuar.",
    );

  // Verificar todo antes de crear o modificar cuentas; no apropiarse de usuarios previos.
  for (const c of cuentas) {
    const u = existentes.find((u) => u.email?.toLowerCase() === c.email);
    if (u && u.app_metadata?.egeo_seed_local !== true)
      throw new Error(
        `${c.email} ya existe y no pertenece a este seed. No se modificó su cuenta.`,
      );
    const previa = guardado?.usuarios.find((x) => x.email === c.email);
    if (
      u &&
      (!previa?.password || typeof previa.password !== "string") &&
      !reiniciar
    )
      throw new Error(
        `Falta la contraseña guardada de ${c.email}. Para regenerar solo las cuentas del seed: npm run db:seed:users -- --reset-passwords`,
      );
  }

  const resultado = {
    version: 1,
    url: url.origin,
    usuarios: cuentas.map((c) => {
      const previa = guardado?.usuarios.find((x) => x.email === c.email);
      return {
        ...c,
        password:
          !reiniciar && typeof previa?.password === "string" && previa.password
            ? previa.password
            : `Egeo-${randomBytes(6).toString("hex")}aA1!`,
      };
    }),
  };
  mkdirSync(".local", { recursive: true });
  const guardar = () =>
    writeFileSync(archivo, JSON.stringify(resultado, null, 2) + "\n", {
      mode: 0o600,
    });
  // Guardar antes del alta permite retomar si se interrumpe el proceso.
  guardar();

  let creados = 0;
  for (const c of resultado.usuarios) {
    let user = existentes.find((u) => u.email?.toLowerCase() === c.email);
    if (!user) {
      ({ user } = await must(
        admin.auth.admin.createUser({
          email: c.email,
          password: c.password,
          email_confirm: true,
          user_metadata: { nombre: c.nombre },
          app_metadata: { egeo_seed_local: true },
        }),
      ));
      creados++;
    } else if (reiniciar) {
      ({ user } = await must(
        admin.auth.admin.updateUserById(user.id, {
          password: c.password,
          email_confirm: true,
        }),
      ));
    }
    c.id = user.id;
    guardar();
    await must(
      admin.from("perfiles").upsert(
        {
          id: user.id,
          nombre: c.nombre,
          rol: c.rol,
          activo: true,
        },
        { onConflict: "id" },
      ),
    );

    // Comprobar el login y el rol mediante la misma RPC que usa la aplicación.
    const cliente = createClient(url.origin, local.ANON_KEY, opciones);
    try {
      await must(
        cliente.auth.signInWithPassword({
          email: c.email,
          password: c.password,
        }),
      );
      const perfil = await must(cliente.rpc("validar_sesion"));
      if (perfil.id !== user.id || perfil.rol !== c.rol || !perfil.activo)
        throw new Error(`No se pudo verificar el perfil de ${c.email}.`);
    } finally {
      await cliente.auth.signOut();
    }
  }
  console.log(
    `Docker local: ${creados} cuentas creadas; ${cuentas.length} logins y roles verificados.`,
  );
  console.table(
    resultado.usuarios.map(({ rol, email, password }) => ({
      rol,
      email,
      password,
    })),
  );
  console.log(`Credenciales guardadas en ${archivo}, excluido de Git.`);
  console.log("Para ingresar: npm run dev:docker → http://127.0.0.1:5173");
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
