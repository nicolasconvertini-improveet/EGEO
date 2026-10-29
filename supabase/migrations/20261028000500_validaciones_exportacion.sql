begin;
create or replace function egeo_privado.configurar_pedido() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.moldes%rowtype; a public.articulos%rowtype;
begin
 if tg_op='UPDATE' then
  if (new.proceso,new.molde_id,new.articulo_id,new.configuracion) is distinct from (old.proceso,old.molde_id,old.articulo_id,old.configuracion) then
   raise exception 'El proceso y la configuración de una orden son inmutables';
  end if;
  return new;
 end if;
 if new.proceso is null then raise exception 'Seleccioná un proceso'; end if;
 if new.proceso='inyectado' then
  perform pg_advisory_xact_lock(hashtextextended(new.molde_id::text,0));
  select * into m from public.moldes where id=new.molde_id and activo for share;
  if not found then raise exception 'Seleccioná un molde activo'; end if;
  perform 1 from public.maquinas where id=m.maquina_id and activo for share;
  if not found then raise exception 'La máquina no está activa'; end if;
  if not exists(select 1 from public.molde_articulos where molde_id=m.id) or exists(
   select 1 from public.molde_articulos ma join public.articulos aa on aa.id=ma.articulo_id where ma.molde_id=m.id and not aa.activo
  ) then raise exception 'El molde debe tener artículos activos'; end if;
  new.configuracion := to_jsonb(m) || jsonb_build_object('maquina_codigo',(select codigo from public.maquinas where id=m.maquina_id));
 else
  select * into a from public.articulos where id=new.articulo_id and activo for share;
  if not found then raise exception 'Seleccioná un artículo activo'; end if;
  if coalesce((to_jsonb(a)->>('std_'||new.proceso))::numeric,0)<=0 then raise exception 'El proceso no está habilitado para este artículo'; end if;
  new.configuracion := jsonb_build_object('codigo',a.codigo,'nombre',a.nombre,'segundos_unidad',(to_jsonb(a)->>('std_'||new.proceso))::numeric);
 end if;
 return new;
end $$;
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
    v_alcance := 'Todas las pausas de tareas. Una pausa abierta no tiene fin ni t_total.';
    v_columnas := '[{"nombre":"nro_orden","tipo":"text"},{"nombre":"usuario","tipo":"text"},
      {"nombre":"motivo","tipo":"text"},{"nombre":"inicio","tipo":"text"},
      {"nombre":"fin","tipo":"text"},{"nombre":"t_total","tipo":"text"}]';
    with f as (
      select pe.codigo nro_orden,
             coalesce(u.nombre, '—') usuario,
             p.motivo,
             to_char(p.inicio, 'YYYY-MM-DD HH24:MI') inicio,
             to_char(p.fin, 'YYYY-MM-DD HH24:MI') fin,
             to_char(date_trunc('second', p.fin - p.inicio), 'HH24:MI:SS') t_total,
             row_number() over (order by p.inicio desc, p.id) orden
      from public.tarea_pausas p
      join public.tareas t on t.id = p.tarea_id
      join public.pedidos pe on pe.id = t.pedido_id
      left join public.perfiles u on u.id = t.operario_id
    )
    select jsonb_build_object('filas', coalesce(jsonb_agg(
             (select jsonb_object_agg(k, v) from jsonb_each_text(to_jsonb(f) - 'orden') x(k, v)) order by f.orden), '[]'::jsonb),
           'total', count(*)::text)
      into v_resultado from f;

  elsif p_reporte = 'tareas' then
    v_alcance := 'Tareas registradas (confirmadas), de la más reciente a la más antigua. No incluye tareas en curso.';
    v_columnas := '[{"nombre":"nro_orden","tipo":"text"},{"nombre":"actividad","tipo":"text"},
      {"nombre":"inicio","tipo":"text"},{"nombre":"fin","tipo":"text"},{"nombre":"operario","tipo":"text"},
      {"nombre":"piezas_ok","tipo":"int4"},{"nombre":"piezas_scrap","tipo":"int4"},{"nombre":"observaciones","tipo":"text"},
      {"nombre":"codigo_articulo","tipo":"text"},{"nombre":"descripcion_articulo","tipo":"text"},
      {"nombre":"cantidad_orden","tipo":"int4"}]';
    with f as (
      select p.codigo nro_orden,
             t.actividad,
             to_char(t.inicio, 'YYYY-MM-DD HH24:MI') inicio,
             to_char(t.fin, 'YYYY-MM-DD HH24:MI') fin,
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
notify pgrst,'reload schema';
commit;
