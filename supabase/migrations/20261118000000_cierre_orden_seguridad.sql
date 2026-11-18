-- Aplicar después de 20261104000000_materiales_montaje.sql.
-- Una única transacción: confirmar producción, bajada y estado, o revertir todo.
begin;
set local lock_timeout='10s';
create function public.finalizar_orden_desde_tarea(
 p_tarea uuid, p_revision integer, p_ok integer default null,
 p_scrap integer default null, p_observaciones text default '',
 p_resultados jsonb default null, p_bajada_minutos numeric default null,
 p_limpieza boolean default false
) returns uuid language plpgsql security definer set search_path='' as $$
declare t public.tareas%rowtype; p public.pedidos%rowtype;
 u public.perfiles%rowtype; av integer; destino text;
begin
 perform public.validar_sesion();
 select * into u from public.perfiles where id=auth.uid() for update;
 select * into t from public.tareas where id=p_tarea and operario_id=u.id for update;
 if not found then raise exception 'La tarea no existe o no te pertenece' using errcode='42501'; end if;
 if t.confirmada or t.fin is null or t.revision is distinct from p_revision then
  raise exception 'La tarea cambió o todavía no está finalizada. Actualizá la pantalla' using errcode='40001';
 end if;
 select * into p from public.pedidos where id=t.pedido_id for no key update;
 if p.estado not in ('pendiente','en_curso') then raise exception 'La orden ya está cerrada o cancelada'; end if;
 -- No bloquear otras tareas después de la orden: gestionar_tarea toma tarea antes que orden.
 -- Todos los inicios y confirmaciones serializan mediante el bloqueo de la orden.
 if exists(select 1 from public.tareas where pedido_id=p.id and id<>t.id and not confirmada) then
  raise exception 'Hay otras tareas abiertas o sin registrar. Registralas antes de finalizar la orden';
 end if;
 if p.requiere_cierre_molde then
  if p_bajada_minutos is null or p_bajada_minutos<0 or p_bajada_minutos>='Infinity'::numeric
     or p_limpieza is distinct from true then
   raise exception 'Registrá los minutos de bajada y confirmá la limpieza del molde';
  end if;
  perform 1 from public.pedido_montajes where pedido_id=p.id and bajado_en is null for update;
  if not found then raise exception 'El montaje no existe o el molde ya fue retirado'; end if;
 end if;
 if p.molde_id is not null then
  perform public.confirmar_tarea_molde(t.id,p_revision,p_resultados,p_observaciones);
 else
  perform public.gestionar_tarea('confirmar',p_tarea=>t.id,p_revision=>p_revision,
   p_ok=>p_ok,p_scrap=>p_scrap,p_observaciones=>p_observaciones);
 end if;
 if p.requiere_cierre_molde then
  update public.pedido_montajes set bajada_minutos=p_bajada_minutos,
   bajado_en=clock_timestamp(),bajado_por=u.id,limpieza_confirmada=true where pedido_id=p.id;
 end if;
 select avance into av from egeo_privado.avance_pedido_interno(p.id);
 destino:=case when coalesce(av,0)>=p.cantidad then 'finalizado' else 'finalizado_pendientes' end;
 -- La confirmación puede haber cerrado automáticamente una orden sin control de molde.
 select * into p from public.pedidos where id=p.id;
 if p.estado is distinct from destino then
  insert into public.pedido_estado_historial(id,pedido_id,estado_anterior,estado_nuevo,accion,
   revision_anterior,revision_nueva,usuario_id,usuario_nombre,usuario_rol,motivo,origen,detalle_proceso)
  values(gen_random_uuid(),p.id,p.estado,destino,'sistema',p.estado_revision,p.estado_revision+1,
   u.id,u.nombre,u.rol,'Finalización de orden confirmada al registrar la tarea','sistema',
   'Cierre operativo sin exigir la cantidad solicitada; tarea '||t.id::text);
  update public.pedidos set estado=destino where id=p.id;
 end if;
 return p.id;
end $$;
revoke all on function public.finalizar_orden_desde_tarea(uuid,integer,integer,integer,text,jsonb,numeric,boolean) from public,anon;
grant execute on function public.finalizar_orden_desde_tarea(uuid,integer,integer,integer,text,jsonb,numeric,boolean) to authenticated;
create or replace function public.exportar_reporte(p_reporte text)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare
  v_columnas jsonb;
  v_resultado jsonb;
  v_alcance text;
begin
  perform public.validar_sesion();
  if auth.uid() is null or not exists (
    select 1 from public.perfiles where id = auth.uid() and activo and rol = 'admin'
  ) then
    raise exception 'Sólo un administrador activo puede exportar datos' using errcode = '42501';
  end if;

  if p_reporte = 'mantenimientos' then
    v_alcance := 'Todos los mantenimientos registrados, del más reciente al más antiguo.';
    v_columnas := '[{"nombre":"registrado_nombre","tipo":"text"},{"nombre":"fecha_ejecucion","tipo":"text"},
      {"nombre":"detalle","tipo":"text"},{"nombre":"preventivo","tipo":"text"},{"nombre":"minutos","tipo":"int4"}]';
    with f as (
      select m.registrado_nombre,
             to_char(m.fecha_ejecucion, 'YYYY-MM-DD') fecha_ejecucion,
             m.detalle,
             case when m.preventivo then 'Sí' else 'No' end preventivo,
             m.minutos,
             row_number() over (order by m.fecha_ejecucion desc, m.creado desc, m.id) orden
      from public.mantenimientos m
    )
    select jsonb_build_object('filas', coalesce(jsonb_agg(
             (select jsonb_object_agg(k, v) from jsonb_each_text(to_jsonb(f) - 'orden') x(k, v)) order by f.orden), '[]'::jsonb),
           'total', count(*)::text)
      into v_resultado from f;

  elsif p_reporte = 'pausas' then
    v_alcance := 'Pausas de tareas y tiempos declarados de montaje/calentamiento/bajada. Para tiempos declarados, inicio indica la fecha de registro y fin queda vacío.';
    v_columnas := '[{"nombre":"nro_orden","tipo":"text"},{"nombre":"usuario","tipo":"text"},{"nombre":"motivo","tipo":"text"},{"nombre":"inicio","tipo":"text"},{"nombre":"fin","tipo":"text"},{"nombre":"t_total","tipo":"text"}]';
    with base as (
      select pe.codigo nro_orden,coalesce(u.nombre,'—') usuario,p.motivo,
       to_char(p.inicio,'YYYY-MM-DD HH24:MI') inicio,to_char(p.fin,'YYYY-MM-DD HH24:MI') fin,
       to_char(date_trunc('second',p.fin-p.inicio),'HH24:MI:SS') t_total,p.inicio fecha,p.id::text clave
      from public.tarea_pausas p join public.tareas t on t.id=p.tarea_id join public.pedidos pe on pe.id=t.pedido_id
      left join public.perfiles u on u.id=t.operario_id
      union all
      select pe.codigo,coalesce(u.nombre,'—'),x.motivo,to_char(x.registrado_en,'YYYY-MM-DD HH24:MI'),null,
       to_char(make_interval(secs=>(x.minutos*60)::double precision),'HH24:MI:SS'),x.registrado_en,x.pedido_id::text||x.motivo
      from public.v_tiempos_molde x join public.pedidos pe on pe.id=x.pedido_id left join public.perfiles u on u.id=x.usuario_id
    ), f as (
      select nro_orden,usuario,motivo,inicio,fin,t_total,row_number() over(order by fecha desc,clave) orden from base
    )
    select jsonb_build_object('filas',coalesce(jsonb_agg(
      (select jsonb_object_agg(k,v) from jsonb_each_text(to_jsonb(f)-'orden') x(k,v)) order by f.orden),'[]'::jsonb),'total',count(*)::text)
    into v_resultado from f;

  elsif p_reporte = 'tareas' then
    v_alcance := 'Tareas registradas (confirmadas), de la más reciente a la más antigua. No incluye tareas en curso.';
    v_columnas := '[{"nombre":"nro_orden","tipo":"text"},{"nombre":"actividad","tipo":"text"},
      {"nombre":"inicio","tipo":"text"},{"nombre":"fin","tipo":"text"},{"nombre":"duracion_minutos","tipo":"float8"},{"nombre":"operario","tipo":"text"},
      {"nombre":"piezas_ok","tipo":"int4"},{"nombre":"piezas_scrap","tipo":"int4"},{"nombre":"observaciones","tipo":"text"},
      {"nombre":"codigo_articulo","tipo":"text"},{"nombre":"descripcion_articulo","tipo":"text"},
      {"nombre":"cantidad_orden","tipo":"int4"}]';
    with f as (
      select p.codigo nro_orden,
             t.actividad,
             to_char(t.inicio, 'YYYY-MM-DD HH24:MI') inicio,
             to_char(t.fin, 'YYYY-MM-DD HH24:MI') fin,
             round((extract(epoch from (t.fin-t.inicio))/60)::numeric,4)::double precision duracion_minutos,
             coalesce(pe.nombre, '—') operario,
             t.piezas_ok,
             t.piezas_scrap,
             nullif(t.observaciones, '') observaciones,
             t.codigo codigo_articulo,
             t.descripcion descripcion_articulo,
             t.cantidad_objetivo cantidad_orden,
             row_number() over (order by t.fin desc, t.tarea_id,t.articulo_id) orden
      from public.v_produccion_articulos t
      join public.pedidos p on p.id = t.pedido_id
      join public.articulos a on a.id = t.articulo_id
      left join public.perfiles pe on pe.id = t.operario_id
      where t.confirmada
    )
    select jsonb_build_object('filas', coalesce(jsonb_agg(
             (select jsonb_object_agg(k, v) from jsonb_each_text(to_jsonb(f) - 'orden') x(k, v)) order by f.orden), '[]'::jsonb),
           'total', count(*)::text)
      into v_resultado from f;

  else
    raise exception 'Reporte no habilitado para exportación' using errcode = '22023';
  end if;

  return v_resultado || jsonb_build_object(
    'tabla', p_reporte,
    'exportado_en', statement_timestamp(),
    'columnas', v_columnas,
    'alcance', v_alcance,
    'fechas', 'Hora de Argentina, texto AAAA-MM-DD HH:MM'
  );
end $$;

-- Defensa adicional: ninguna función con privilegios de propietario se ofrece
-- anónimamente. Conservar los GRANT explícitos de las RPC autenticadas.
do $$ declare f record; begin
 for f in select p.oid::regprocedure firma from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname in ('public','egeo_privado') and p.prosecdef
  and not exists(select 1 from pg_depend d where d.objid=p.oid and d.deptype='e')
 loop execute format('revoke execute on function %s from public,anon',f.firma); end loop;
end $$;
notify pgrst,'reload schema';
commit;
