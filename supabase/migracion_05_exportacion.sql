begin;

-- Una respuesta JSON escalar evita el límite de filas de los endpoints tabulares.
-- STABLE conserva la instantánea de la consulta durante toda la lectura.
create or replace function public.exportar_tabla_completa(p_tabla text)
returns jsonb
language plpgsql stable security definer
set search_path = ''
set timezone = 'UTC'
as $$
declare
  v_columnas jsonb;
  v_resultado jsonb;
begin
  if auth.uid() is null or not exists (
    select 1 from public.perfiles
    where id = auth.uid() and activo and rol = 'admin'
  ) then
    raise exception 'Sólo un administrador activo puede exportar datos'
      using errcode = '42501';
  end if;

  if p_tabla is null or p_tabla not in
    ('tarea_pausas', 'tareas', 'articulos', 'pedidos') then
    raise exception 'Tabla no habilitada para exportación'
      using errcode = '22023';
  end if;

  select jsonb_agg(jsonb_build_object(
    'nombre', a.attname, 'tipo', ty.typname
  ) order by a.attnum) into v_columnas
  from pg_catalog.pg_attribute a
  join pg_catalog.pg_class c on c.oid = a.attrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_type ty on ty.oid = a.atttypid
  where n.nspname = 'public' and c.relname = p_tabla
    and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped;

  if v_columnas is null then
    raise exception 'La tabla no existe. Revisá las migraciones aplicadas';
  end if;

  -- Valores como texto o null en el transporte para no perder precisión
  -- de numeric/bigint al pasar por JSON y JavaScript. Todas las columnas.
  execute format($sql$
    select jsonb_build_object(
      'tabla', $1,
      'exportado_en', statement_timestamp(),
      'columnas', $2,
      'total', count(*)::text,
      'filas', coalesce(jsonb_agg(
        (select jsonb_object_agg(k, v)
         from jsonb_each_text(to_jsonb(t)) as valores(k, v))
        order by t.id
      ), '[]'::jsonb)
    )
    from public.%I as t
  $sql$, p_tabla)
  into v_resultado using p_tabla, v_columnas;

  return v_resultado;
end;
$$;

revoke all on function public.exportar_tabla_completa(text) from public, anon;
grant execute on function public.exportar_tabla_completa(text) to authenticated;
notify pgrst, 'reload schema';
commit;
