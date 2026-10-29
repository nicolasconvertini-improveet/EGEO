import http from "node:http";
import { crearServidor } from "./local-server-core.mjs";
import { loadEnv } from "vite";
const mode = process.argv[2] || "development";
Object.assign(process.env, loadEnv(mode, process.cwd(), ""));
const apiUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL;
if (!apiUrl) throw new Error("Falta SUPABASE_URL o VITE_SUPABASE_URL.");
const url = new URL(apiUrl);
const docker = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
if ((mode === "docker") !== docker)
  throw new Error(
    "La conexión no corresponde al modo elegido. Docker requiere npm run dev:docker.",
  );
if (
  process.env.VITE_SUPABASE_URL &&
  new URL(process.env.VITE_SUPABASE_URL).origin !== url.origin
)
  throw new Error(
    "Frontend y funciones deben usar el mismo proyecto Supabase.",
  );
process.env.SUPABASE_URL = apiUrl;
if (!process.env.SUPABASE_SERVICE_ROLE_KEY)
  console.log(
    "Falta SUPABASE_SERVICE_ROLE_KEY en el servidor: la administración de usuarios requiere configurarla.",
  );
const handlers = {
  "crear-usuario": (await import("../netlify/functions/crear-usuario.js"))
    .handler,
  "cambiar-password": (await import("../netlify/functions/cambiar-password.js"))
    .handler,
};
http
  .createServer(crearServidor(handlers))
  .listen(5174, "127.0.0.1", () =>
    console.log("Funciones de desarrollo: " + url.origin),
  );
