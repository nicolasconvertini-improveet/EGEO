import { spawnSync } from "node:child_process";
import { writeFileSync, readFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { estadoLocal } from "./local-config.mjs";
estadoLocal();
const container = "supabase_db_egeo-qa";
function docker(args, options = {}) {
  const r = spawnSync("docker", args, {
    maxBuffer: 256 * 1024 * 1024,
    ...options,
  });
  if (r.status !== 0) throw new Error(r.stderr?.toString() || "Falló Docker");
  return r.stdout;
}
const [accion, archivo, nombre] = process.argv.slice(2);
if (accion === "backup") {
  mkdirSync("backups", { recursive: true });
  const dest = resolve(
    archivo ||
      `backups/egeo-${new Date().toISOString().replace(/[:.]/g, "-")}.dump`,
  );
  if (existsSync(dest))
    throw new Error("El respaldo ya existe; elegí otro archivo.");
  const bytes = docker([
    "exec",
    container,
    "pg_dump",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "-Fc",
    "--no-owner",
    "--no-acl",
    "-n",
    "public",
    "-n",
    "auth",
    "-n",
    "egeo_privado",
    "-n",
    "supabase_migrations",
  ]);
  writeFileSync(dest, bytes);
  console.log("Respaldo guardado: " + dest);
} else if (accion === "restore") {
  if (!archivo || !/^egeo_restore_[a-z0-9_]+$/.test(nombre || ""))
    throw new Error(
      "Uso: restore archivo.dump egeo_restore_nombre. Solo se restaura a una base nueva de prueba.",
    );
  const bytes = readFileSync(archivo);
  docker([
    "exec",
    container,
    "createdb",
    "-U",
    "postgres",
    "-T",
    "template0",
    nombre,
  ]);
  docker([
    "exec",
    container,
    "psql",
    "-U",
    "postgres",
    "-d",
    nombre,
    "-v",
    "ON_ERROR_STOP=1",
    "-c",
    "DROP SCHEMA public; CREATE SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;",
  ]);
  docker(
    [
      "exec",
      "-i",
      container,
      "pg_restore",
      "-U",
      "postgres",
      "-d",
      nombre,
      "--no-owner",
      "--no-acl",
      "--exit-on-error",
    ],
    { input: bytes },
  );
  console.log(
    "Respaldo restaurado a base aislada " +
      nombre +
      ". La base activa no fue modificada.",
  );
} else throw new Error("Acción requerida: backup o restore");
