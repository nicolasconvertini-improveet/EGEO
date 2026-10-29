import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "VITE_");
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
