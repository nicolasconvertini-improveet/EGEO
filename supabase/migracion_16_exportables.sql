-- Aplicar DESPUÉS de la migración 15.
-- Exportables a medida (pedido de Matías). Devuelve el mismo formato que
-- exportar_tabla_completa, así el armado del Excel no cambia:
--   mantenimientos: registrado_nombre, fecha_ejecucion, detalle, preventivo, minutos
--   pausas:         nro_orden, usuario, motivo, inicio, fin, t_total
--   tareas:         nro_orden, actividad, inicio, fin, operario, piezas_ok, piezas_scrap,
--                   observaciones, codigo_articulo, descripcion_articulo, cantidad_orden
-- Artículos sigue usando exportar_tabla_completa('articulos') (maestro completo).
-- Fechas y horas en hora de Argentina, como texto AAAA-MM-DD HH:MM (ordena bien en Excel).
begin;

create or replace function public.exportar_reporte(p_reporte text)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare
  v_columnas jsonb;
  v_resultado jsonb;
  v_alcance text;
begin
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
             a.codigo codigo_articulo,
             a.nombre descripcion_articulo,
             p.cantidad cantidad_orden,
             row_number() over (order by t.fin desc, t.id) orden
      from public.tareas t
      join public.pedidos p on p.id = t.pedido_id
      join public.articulos a on a.id = p.articulo_id
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

revoke all on function public.exportar_reporte(text) from public, anon;
grant execute on function public.exportar_reporte(text) to authenticated;
notify pgrst, 'reload schema';
commit;