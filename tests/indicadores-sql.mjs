import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const { PGlite } = await import(
  process.env.EGEO_PGLITE_MODULE ? pathToFileURL(process.env.EGEO_PGLITE_MODULE).href : "@electric-sql/pglite"
);
import fs from "node:fs";
import assert from "node:assert/strict";
const db = new PGlite();
await db.exec(`
create role anon; create role authenticated; create schema egeo_privado;
create function egeo_privado.sesion_activa() returns boolean language sql as $$select current_setting('test.active',true)='yes'$$;
create function public.rol_actual() returns text language sql as $$select current_setting('test.role',true)$$;
create table articulos(id uuid primary key,codigo text,nombre text,std_inyectado numeric,std_rebabado numeric,std_armado numeric,std_embolsado numeric,categoria text);
create table pedidos(id uuid primary key,codigo text,articulo_id uuid,estado text);
create table tareas(id uuid primary key,pedido_id uuid,actividad text,inicio timestamptz,fin timestamptz,confirmada boolean,piezas_ok integer,piezas_scrap integer);
create table tarea_pausas(id uuid primary key,tarea_id uuid,inicio timestamptz,fin timestamptz);
create table mantenimientos(id uuid,fecha_ejecucion date,minutos integer,preventivo boolean);
create table pedido_estado_historial(pedido_id uuid,estado_nuevo text,creado timestamptz);
create view v_tareas as select t.*,p.codigo pedido_codigo,p.articulo_id,a.nombre articulo_nombre,
extract(epoch from(t.fin-t.inicio))-coalesce((select sum(extract(epoch from(x.fin-x.inicio))) from tarea_pausas x where x.tarea_id=t.id),0) real_seg,
t.piezas_ok * (case t.actividad when 'inyectado' then a.std_inyectado when 'embolsado' then a.std_embolsado end) std_seg
from tareas t join pedidos p on p.id=t.pedido_id join articulos a on a.id=p.articulo_id;
set test.active='yes'; set test.role='admin';
`);
const sql = fs.readFileSync(new URL("../supabase/migracion_11_indicadores.sql", import.meta.url), "utf8");
await db.exec(sql);
const v2 = fs.readFileSync(root + "/supabase/migracion_12_indicadores_admin_filtros.sql", "utf8");
await db.exec(v2);
await db.exec(v2);
const v3 = fs.readFileSync(root + "/supabase/migracion_13_indicadores_rendimiento.sql", "utf8");
await db.exec(v3);
await db.exec(v3);
let n = 0;
const eq = (a, b) => {
  assert.equal(a, b);
  n++;
};
async function query(desde = "2000-10-01", hasta = "2000-10-02", art = null, proc = "") {
  return (await db.query("select public.indicadores_egeo_v2($1,$2,$3,$4) r", [desde, hasta, art, proc])).rows[0].r;
}
let r = await query();
eq(r.dias.length, 2);
eq(r.tareas.length, 0);
eq(Number(r.dias[0].real), 0);
await db.exec(`
insert into articulos values('00000000-0000-0000-0000-000000000001','A','Artículo A',60,0,0,60);
insert into pedidos values('00000000-0000-0000-0000-000000000002','P','00000000-0000-0000-0000-000000000001','finalizado');
insert into tareas values('00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','embolsado','2000-10-01 23:00:00-03','2000-10-02 01:00:00-03',true,90,10);
insert into tarea_pausas values('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000003','2000-10-01 23:45:00-03','2000-10-02 00:15:00-03');
insert into mantenimientos values('00000000-0000-0000-0000-000000000005','2000-10-01',30,false);
insert into pedido_estado_historial values('00000000-0000-0000-0000-000000000002','finalizado','2000-10-02 01:01:00-03'),('00000000-0000-0000-0000-000000000002','finalizado','2000-10-02 02:00:00-03');
`);
r = await query();
eq(r.tareas.length, 1);
eq(Number(r.tareas[0].real_seg), 5400);
eq(Number(r.dias[0].real), 2700);
eq(Number(r.dias[1].real), 2700);
eq(Number(r.dias[0].pausa_seg), 900);
eq(Number(r.dias[1].pausa_seg), 900);
eq(Number(r.dias[0].pausas), 1);
eq(Number(r.dias[1].pausas), 0);
eq(Number(r.dias[0].piezas), 0);
eq(Number(r.dias[1].piezas), 90);
eq(Number(r.dias[1].ordenes), 1);
eq(Number(r.dias[0].mantenimiento_seg), 1800);
eq(Number(r.dias[0].correctivo_seg), 1800);
eq(Number(r.dias[1].tareas), 1);
r = await query("2000-10-01", "2000-10-02", []);
eq(r.tareas.length, 0);
eq(Number(r.dias[0].mantenimiento_seg), 1800);
eq(Number(r.dias[1].ordenes), 0);
r = await query("2000-10-01", "2000-10-02", null, "inyectado");
eq(r.tareas.length, 0);
eq(Number(r.dias[1].ordenes), 1);
eq(Number(r.dias[0].pausa_seg), 0);
r = await query("2000-10-01", "2000-10-02", ["00000000-0000-0000-0000-000000000001"]);
eq(r.tareas.length, 1);
eq(r.catalogo.length, 1);
eq(r.catalogo[0].codigo, "A");
await db.exec("set role authenticated");
await assert.rejects(() => db.query("select public.indicadores_egeo('2000-10-01','2000-10-02','','')"));
n++;
await db.exec("reset role");
await db.exec("set test.role='supervisor'");
await assert.rejects(() => query());
n++;
async function rejects(f) {
  await assert.rejects(f);
  n++;
}
await db.exec("set test.role='operario'");
await rejects(() => query());
await db.exec("set test.role='admin';set test.active='no'");
await rejects(() => query());
await db.exec("set test.active='yes'");
await rejects(() => query("2000-10-02", "2000-10-01"));
await rejects(() => query("2000-01-01", "2000-12-31"));
await rejects(() => query("2000-10-01", "2000-10-02", null, "invalid"));
await db.exec(
  `insert into tareas values('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000002','inyectado','2000-10-02 02:00:00-03','2000-10-02 03:00:00-03',true,90,0)`,
);
r = await query();
eq(Number(r.dias[1].piezas), 90);
eq(r.tareas.length, 2);
await db.exec("update articulos set std_inyectado=0,std_embolsado=0");
r = await query();
eq(Number(r.sin_etapas), 2);
eq(Number(r.dias[1].piezas), 0);
await db.exec("delete from pedido_estado_historial");
r = await query();
eq(Number(r.finalizadas_sin_fecha), 1);
eq(Number(r.dias[1].ordenes), 0);
await db.exec(
  `insert into tareas select md5(i::text)::uuid,'00000000-0000-0000-0000-000000000002','inyectado','2000-10-02 04:00:00-03','2000-10-02 05:00:00-03',true,1,0 from generate_series(1,1100) i`,
);
eq((await query()).tareas.length, 1102);
await db.exec("set role anon");
await rejects(() => query());
await db.exec("reset role");
await db.exec("set test.role='';");
await rejects(() => query());
await db.exec("set test.role='admin';");
await rejects(() => query("infinity", "infinity"));
await rejects(() => query("2999-01-01", "2999-01-01"));
await db.exec(
  "insert into tareas select md5(('extra'||i)::text)::uuid,'00000000-0000-0000-0000-000000000002','inyectado','2000-10-02 04:00:00-03','2000-10-02 05:00:00-03',true,1,0 from generate_series(1,19000) i",
);
await rejects(() => query());
eq((await query("2000-10-01", "2000-10-02", [])).tareas.length, 0);
eq((await query("2000-10-01", "2000-10-02", null, "embolsado")).tareas.length, 1);
console.log(n + " verificaciones SQL correctas (PostgreSQL local; esquema y sesión simulados)");
await db.close();
