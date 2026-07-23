-- =====================================================================
--  Migración 01 — tareas persistentes (abiertas / pendientes / confirmadas)
--  Ejecutar UNA vez en: Supabase → SQL Editor → New query → Run
--  Es idempotente: se puede correr más de una vez sin romper nada.
-- =====================================================================

-- 1) La tarea ahora se crea al INICIAR: el fin queda vacío hasta finalizar.
alter table public.tareas alter column fin drop not null;

-- 2) Marca de tarea confirmada (con piezas cargadas). Las no confirmadas
--    no suman en pedidos ni en el tablero.
alter table public.tareas add column if not exists confirmada boolean not null default false;

-- Las tareas que ya existían se consideran confirmadas.
update public.tareas set confirmada = true where fin is not null and confirmada = false;

-- 3) Un operario no puede tener más de una tarea abierta a la vez.
create unique index if not exists uq_tarea_abierta_por_operario
  on public.tareas (operario_id) where fin is null;

-- 4) El avance del pedido sólo cuenta tareas confirmadas.
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_total  int;
  v_meta   int;
begin
  select coalesce(sum(piezas_ok),0) into v_total
    from public.tareas where pedido_id = v_pedido and confirmada = true;
  select cantidad into v_meta from public.pedidos where id = v_pedido;
  update public.pedidos
     set estado = case
       when v_total >= v_meta then 'finalizado'
       when v_total > 0       then 'en_curso'
       else 'pendiente' end
   where id = v_pedido;
  return null;
end; $$;

-- 5) Vistas actualizadas
--    Se borran primero porque cambian sus columnas (Postgres no permite
--    hacerlo con "create or replace").
drop view if exists public.v_pedido_etapas;
drop view if exists public.v_tareas;
drop view if exists public.v_pedidos;

create or replace view public.v_pedidos with (security_invoker = on) as
  select p.id, p.codigo, p.articulo_id,
         a.nombre as articulo_nombre, a.codigo as articulo_codigo,
         p.cantidad, p.estado, p.creado,
         coalesce(sum(t.piezas_ok)  filter (where t.confirmada),0)::int as ok_acum,
         coalesce(sum(t.piezas_scrap) filter (where t.confirmada),0)::int as scrap_acum
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
    left join public.tareas t on t.pedido_id = p.id
   group by p.id, a.nombre, a.codigo;

create or replace view public.v_tareas with (security_invoker = on) as
  select t.id, t.pedido_id, p.codigo as pedido_codigo, p.articulo_id,
         a.nombre as articulo_nombre, t.actividad,
         coalesce(pe.nombre,'—') as operario_nombre, t.operario_id,
         t.inicio, t.fin, t.piezas_ok, t.piezas_scrap, t.creado, t.confirmada,
         case when t.fin is null then null
              else greatest(1, extract(epoch from (t.fin - t.inicio)))::int end as real_seg,
         (t.piezas_ok * (case t.actividad
            when 'inyectado' then a.std_inyectado
            when 'rebabado'  then a.std_rebabado
            when 'armado'    then a.std_armado
            when 'embolsado' then a.std_embolsado end))::numeric as std_seg
    from public.tareas t
    join public.pedidos p on p.id = t.pedido_id
    join public.articulos a on a.id = p.articulo_id
    left join public.perfiles pe on pe.id = t.operario_id;

-- 6) Totales por etapa de cada pedido (siempre las 4 actividades, en cero si no hubo)
create or replace view public.v_pedido_etapas with (security_invoker = on) as
  select p.id as pedido_id,
         e.actividad,
         coalesce(sum(t.piezas_ok)  filter (where t.confirmada),0)::int as ok,
         coalesce(sum(t.piezas_scrap) filter (where t.confirmada),0)::int as scrap,
         count(t.id) filter (where t.confirmada)::int as tareas
    from public.pedidos p
   cross join (values ('inyectado'),('rebabado'),('armado'),('embolsado')) as e(actividad)
    left join public.tareas t
           on t.pedido_id = p.id and t.actividad = e.actividad
   group by p.id, e.actividad;
