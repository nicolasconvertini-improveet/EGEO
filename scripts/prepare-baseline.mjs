import { readFileSync, writeFileSync, readdirSync } from "node:fs";

const root = new URL("../", import.meta.url);
const sources = [
  "schema.sql",
  ...readdirSync(new URL("supabase/", root))
    .filter((n) => /^migracion_\d+/.test(n))
    .sort((a, b) => Number(a.match(/\d+/)[0]) - Number(b.match(/\d+/)[0])),
];
// Baseline exacto del historial versionado; no incluye seed ni scripts ad hoc.
const sql = sources
  .map(
    (n) =>
      `-- Origen: ${n}\n${readFileSync(new URL("supabase/" + n, root), "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/\r\n/g, "\n")}`,
  )
  .join("\n\n");
const file = new URL("supabase/migrations/20261028000000_baseline.sql", root);
if (process.argv.includes("--check")) {
  if (readFileSync(file, "utf8").replace(/\r\n/g, "\n") !== sql)
    throw new Error("Baseline desactualizado");
} else writeFileSync(file, sql);
console.log(`Baseline: ${sources.length} scripts históricos`);
