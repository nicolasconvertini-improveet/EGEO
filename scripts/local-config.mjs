import { execFileSync } from "node:child_process";
export function estadoLocal() {
  const raw = execFileSync(
    process.execPath,
    ["node_modules/supabase/dist/supabase.js", "status", "-o", "json"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  const result = JSON.parse(raw);
  if (new URL(result.API_URL).hostname !== "127.0.0.1")
    throw new Error("Se requiere la instancia Docker local");
  return result;
}
