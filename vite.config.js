import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "VITE_");
  // Vite publica todas las variables VITE_: fallar antes de empaquetar secretos.
  for (const [nombre, valor] of Object.entries(env)) {
    let privilegiada = valor.startsWith("sb_secret_");
    if (valor.split(".").length === 3) {
      try {
        privilegiada ||=
          JSON.parse(Buffer.from(valor.split(".")[1], "base64url").toString())
            .role === "service_role";
      } catch {
        /* Otros valores públicos pueden contener puntos. */
      }
    }
    if (
      privilegiada ||
      (/SECRET|SERVICE_ROLE|PASSWORD|PRIVATE_KEY/i.test(nombre) && valor)
    )
      throw new Error(
        "Una variable VITE_ contiene un secreto. Configurala sólo en el servidor.",
      );
  }
  if (env.VITE_SUPABASE_URL) {
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(
      new URL(env.VITE_SUPABASE_URL).hostname,
    );
    if (local && mode !== "docker")
      throw new Error(
        "Docker está configurado como entorno predeterminado. Usá .env.docker.local y npm run dev:docker.",
      );
  }
  return {
    plugins: [react()],
    server: { proxy: { "/.netlify/functions": "http://127.0.0.1:5174" } },
  };
});
