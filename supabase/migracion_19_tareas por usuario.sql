-- Aplicar DESPUÉS de la migración 18.
-- El operario sólo puede leer SUS tareas y pausas. Supervisor y admin leen todo.
-- Los totales de las órdenes (avance por etapa y scrap) se siguen calculando
-- con TODAS las tareas, a través de funciones del propietario.
begin;

-- 1) Lectura de tareas y pausas por rol ------------------------------------
drop policy if exists tareas_select on public.tareas;
create policy tareas_select on public.tareas for select to authenticated
  using (operario_id = auth.uid() or public.rango(public.rol_actual()) >= 2);

drop policy if exists pausas_select on public.tarea_pausas;
create policy pausas_select on public.tarea_pausas for select to authenticated
  using (
    public.rango(public.rol_actual()) >= 2
    or exists (select 1 from public.tareas t where t.id = tarea_id and t.operario_id = auth.uid())
  );

-- 2) Totales por etapa con todas las tareas --------------------------------
create or replace function egeo_privado.pedido_etapas()
returns table(pedido_id uuid, actividad text, ok int, scrap int, tareas int)
language sql stable security definer set search_path = '' as $$
  select p.id, e.actividad,
         coalesce(sum(t.piezas_ok)    filter (where t.confirmada), 0)::int,
         coalesce(sum(t.piezas_scrap) filter (where t.confirmada), 0)::int,
         count(t.id) filter (where t.confirmada)::int
    from public.pedidos p
   cross join (values ('inyectado'),('rebabado'),('armado'),('embolsado')) as e(actividad)
    left join public.tareas t on t.pedido_id = p.id and t.actividad = e.actividad
   where (select egeo_privado.sesion_activa())
   group by p.id, e.actividad;
$$;
revoke all on function egeo_privado.pedido_etapas() from public, anon;
grant execute on function egeo_privado.pedido_etapas() to authenticated;

create or replace view public.v_pedido_etapas with (security_invoker = on) as
  select pedido_id, actividad, ok, scrap, tareas from egeo_privado.pedido_etapas();

-- 3) Scrap acumulado de la orden con todas las tareas ----------------------
create or replace function egeo_privado.scrap_pedido(p_pedido uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce(sum(t.piezas_scrap), 0)::int from public.tareas t
   where t.pedido_id = p_pedido and t.confirmada and (select egeo_privado.sesion_activa());
$$;
revoke all on function egeo_privado.scrap_pedido(uuid) from public, anon;
grant execute on function egeo_privado.scrap_pedido(uuid) to authenticated;

-- Mismas columnas, mismo orden que la migración 08; sólo cambia scrap_acum.
create or replace view public.v_pedidos with (security_invoker = on) as
select p.id, p.codigo, p.articulo_id, a.nombre as articulo_nombre, a.codigo as articulo_codigo,
  p.cantidad, p.estado, p.creado, av.avance as ok_acum, av.bruto as ok_bruto,
  av.etapas_req, av.etapas_completas,
  egeo_privado.scrap_pedido(p.id) as scrap_acum,
  p.estado_revision
from public.pedidos p join public.articulos a on a.id = p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;

notify pgrst, 'reload schema';
commit;