import http from "node:http";
import { crearServidor } from "./local-server-core.mjs";
import { loadEnv } from "vite";
Object.assign(process.env, loadEnv("development", process.cwd(), ""));
const url = new URL(process.env.SUPABASE_URL || "http://127.0.0.1:54321");
if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))
  throw new Error("El servidor local solo admite Supabase local.");
const handlers = {
  "crear-usuario": (await import("../netlify/functions/crear-usuario.js"))
    .handler,
  "cambiar-password": (await import("../netlify/functions/cambiar-password.js"))
    .handler,
};
http
  .createServer(crearServidor(handlers))
  .listen(5174, "127.0.0.1", () =>
    console.log("Funciones locales: http://127.0.0.1:5174"),
  );
