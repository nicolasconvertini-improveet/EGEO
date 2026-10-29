import { readFileSync, writeFileSync, readdirSync } from "node:fs";

const baseline = "20261028000000_baseline.sql";
const files = readdirSync("supabase/migrations")
  .filter(
    (f) =>
      /^\d+.*\.sql$/.test(f) &&
      f > baseline &&
      f <= "20261029000000_inyectado_ciclos.sql",
  )
  .sort();
const preflight = `-- Solo para la base existente que ya tiene las migraciones históricas 01–19.
do $preflight$
declare missing text;
begin
 select string_agg(name, ', ') into missing from unnest(array[
  'public.perfiles','public.articulos','public.pedidos','public.tareas',
  'public.tarea_pausas','public.mantenimientos','public.pedido_cantidad_historial','public.tarea_auditoria'
 ]) name where to_regclass(name) is null;
 if missing is not null then raise exception 'Falta el esquema histórico: %',missing; end if;
 if to_regprocedure('egeo_privado.sesion_activa()') is null or to_regprocedure('public.validar_sesion()') is null then
  raise exception 'Faltan migraciones históricas de sesiones. Revisar 01–19 antes de continuar';
 end if;
 if to_regclass('public.maquinas') is not null or to_regclass('public.moldes') is not null
    or to_regclass('public.solicitudes_trabajo') is not null then
  raise exception 'Hay cambios QA aplicados previamente. No repetir este paquete: revisar las migraciones pendientes';
 end if;
end $preflight$;
`;
const body = files
  .map(
    (f) =>
      `-- Migración: ${f}\n${readFileSync("supabase/migrations/" + f, "utf8")
        .replace(/^\uFEFF/, "")
        .replace(/\r\n/g, "\n")
        .replace(/^\s*(begin|commit);\s*$/gim, "")}`,
  )
  .join("\n\n");
const sql = `-- GENERADO por npm run release:sql. No editar manualmente.
-- Proyecto destino esperado: gplitedrfmlakjghfeud. Ver docs/despliegue-supabase.md.
-- No contiene baseline ni semillas ni limpieza de datos de prueba.
-- Ejecutar COMPLETO en una sola consulta. Ante error: ROLLBACK antes de reintentar.
begin;
set local lock_timeout = '10s';
select pg_advisory_xact_lock(hashtextextended('EGEO:release:20261029',0));
${preflight}
${body}

create table if not exists egeo_privado.despliegues (
 version text primary key, aplicado_en timestamptz not null default now()
);
revoke all on egeo_privado.despliegues from public,anon,authenticated;
insert into egeo_privado.despliegues(version) values ('20261029_qa_produccion');
notify pgrst, 'reload schema';
commit;
`;
const outputs = {
  "supabase/releases/00_verificar_base_real.sql":
    "-- Comprobación sin modificaciones. Un error indica que hay que revisar el esquema.\n" +
    preflight +
    "\nselect current_database(), 'Esquema inicial compatible; verificar también historial 01–19 y respaldo' as resultado;\n",
  "supabase/releases/20261029_actualizacion_produccion.sql": sql,
};
for (const [path, content] of Object.entries(outputs)) {
  if (process.argv.includes("--check")) {
    if (readFileSync(path, "utf8").replace(/\r\n/g, "\n") !== content)
      throw new Error("Regenerar " + path + " con npm run release:sql");
  } else writeFileSync(path, content);
}
console.log(
  `${files.length} migraciones incrementales; ${process.argv.includes("--check") ? "paquete verificado" : "paquete generado"}. No se conectó a ninguna base.`,
);
