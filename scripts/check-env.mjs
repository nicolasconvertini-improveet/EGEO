import { loadEnv } from "vite";
const mode = process.argv.includes("--docker") ? "docker" : "development";
const e = loadEnv(mode, process.cwd(), "");
const url = new URL(e.VITE_SUPABASE_URL || "http://missing.invalid");
const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
if (url.hostname === "missing.invalid" || local !== (mode === "docker"))
  throw new Error("La URL no corresponde al entorno elegido.");
const key = e.VITE_SUPABASE_ANON_KEY || "";
if (!key || key.includes("REEMPLAZAR") || key.startsWith("sb_secret_"))
  throw new Error(
    "Configurá la clave pública del proyecto; nunca una clave de servicio en VITE_.",
  );
if (key.split(".").length === 3) {
  const claims = JSON.parse(
    Buffer.from(key.split(".")[1], "base64url").toString(),
  );
  if (claims.role !== "anon")
    throw new Error(
      "La clave VITE_SUPABASE_ANON_KEY debe ser pública (rol anon).",
    );
}
if (e.SUPABASE_URL && new URL(e.SUPABASE_URL).origin !== url.origin)
  throw new Error("El servidor apunta a otro proyecto.");
console.log("Frontend: " + url.origin + " · clave pública configurada.");
console.log(
  "Servidor de usuarios: " +
    (e.SUPABASE_SERVICE_ROLE_KEY
      ? "clave de servicio configurada."
      : "falta SUPABASE_SERVICE_ROLE_KEY (solo servidor)."),
);
if (process.argv.includes("--require-server") && !e.SUPABASE_SERVICE_ROLE_KEY)
  process.exitCode = 1;
