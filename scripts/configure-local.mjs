import { estadoLocal } from "./local-config.mjs";
import { writeFileSync, existsSync } from "node:fs";
const s = estadoLocal();
if (existsSync(".env.local") && !process.argv.includes("--replace"))
  throw new Error(".env.local ya existe. No se sobrescribe.");
writeFileSync(
  ".env.local",
  `VITE_SUPABASE_URL=${s.API_URL}\nVITE_SUPABASE_ANON_KEY=${s.ANON_KEY}\nSUPABASE_URL=${s.API_URL}\nSUPABASE_SERVICE_ROLE_KEY=${s.SERVICE_ROLE_KEY}\n`,
);
console.log("Configuración local guardada en .env.local (ignorada por Git).");
