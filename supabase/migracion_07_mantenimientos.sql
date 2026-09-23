begin;

create table if not exists public.mantenimientos (
  id uuid primary key default gen_random_uuid(),
  registrado_por uuid not null references public.perfiles(id) on delete restrict,
  registrado_nombre text not null,
  ejecutor_id uuid not null references public.perfiles(id) on delete restrict,
  ejecutor_nombre text not null,
  fecha_ejecucion date not null,
  detalle text not null check (char_length(btrim(detalle)) between 1 and 5000),
  preventivo boolean not null,
  minutos integer not null check (minutos > 0),
  creado timestamptz not null default now()
);

alter table public.mantenimientos enable row level security;
drop policy if exists mantenimientos_lectura on public.mantenimientos;
create policy mantenimientos_lectura on public.mantenimientos for select
  to authenticated using (public.rol_actual() in ('admin', 'supervisor'));
revoke all on public.mantenimientos from public, anon, authenticated;
grant select on public.mantenimientos to authenticated;

-- Catálogo completo: la respuesta escalar no queda limitada a 1000 perfiles.
create or replace function public.ejecutores_mantenimiento()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null or public.rol_actual() not in ('admin', 'supervisor')
     or public.rol_actual() is null then
    raise exception 'Se requiere un administrador o supervisor activo' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre)
    order by nombre, id), '[]'::jsonb) from public.perfiles where activo);
end;
$$;

-- El cliente no envía el registrante ni los nombres: se toman de la sesión/base.
-- Reintentar el mismo UUID y contenido devuelve el registro sin duplicarlo.
create or replace function public.registrar_mantenimiento(
  p_id uuid, p_ejecutor_id uuid, p_fecha_ejecucion date,
  p_detalle text, p_preventivo boolean, p_minutos integer
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_registrante public.perfiles%rowtype;
  v_ejecutor public.perfiles%rowtype;
  v_registro public.mantenimientos%rowtype;
begin
  select * into v_registrante from public.perfiles where id = auth.uid() for share;
  if not found or not v_registrante.activo or v_registrante.rol not in ('admin', 'supervisor') then
    raise exception 'Se requiere un administrador o supervisor activo' using errcode = '42501';
  end if;
  if p_id is null or p_fecha_ejecucion is null or not isfinite(p_fecha_ejecucion)
     or p_preventivo is null or p_minutos is null or p_minutos <= 0
     or p_detalle is null or char_length(btrim(p_detalle)) not between 1 and 5000 then
    raise exception 'Completá fecha, detalle (1 a 5000 caracteres), tipo y minutos enteros positivos'
      using errcode = '22023';
  end if;
  select * into v_ejecutor from public.perfiles where id = p_ejecutor_id for share;
  if not found or not v_ejecutor.activo then
    raise exception 'El ejecutor debe ser un usuario activo' using errcode = '22023';
  end if;
  insert into public.mantenimientos (
    id, registrado_por, registrado_nombre, ejecutor_id, ejecutor_nombre,
    fecha_ejecucion, detalle, preventivo, minutos
  ) values (
    p_id, v_registrante.id, v_registrante.nombre, v_ejecutor.id, v_ejecutor.nombre,
    p_fecha_ejecucion, btrim(p_detalle), p_preventivo, p_minutos
  ) on conflict (id) do nothing;
  select * into v_registro from public.mantenimientos where id = p_id;
  if v_registro.registrado_por <> auth.uid()
     or v_registro.ejecutor_id <> p_ejecutor_id
     or v_registro.fecha_ejecucion <> p_fecha_ejecucion
     or v_registro.detalle <> btrim(p_detalle)
     or v_registro.preventivo <> p_preventivo or v_registro.minutos <> p_minutos then
    raise exception 'El identificador ya corresponde a otro registro' using errcode = '22023';
  end if;
  return to_jsonb(v_registro);
end;
$$;

-- Misma lectura para entrar a la pantalla y para descargar todo el historial.
create or replace function public.exportar_mantenimientos()
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC'
as $$
declare v_columnas jsonb;
begin
  if auth.uid() is null or public.rol_actual() not in ('admin', 'supervisor')
     or public.rol_actual() is null then
    raise exception 'Se requiere un administrador o supervisor activo' using errcode = '42501';
  end if;
  select jsonb_agg(jsonb_build_object('nombre', a.attname, 'tipo', t.typname)
    order by a.attnum) into v_columnas
  from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid = a.atttypid
  where a.attrelid = 'public.mantenimientos'::regclass and a.attnum > 0 and not a.attisdropped;
  return (select jsonb_build_object(
    'tabla', 'mantenimientos', 'exportado_en', statement_timestamp(),
    'columnas', v_columnas, 'total', count(*)::text,
    'filas', coalesce(jsonb_agg(
      (select jsonb_object_agg(k, v) from jsonb_each_text(to_jsonb(m)) as datos(k, v))
      order by m.fecha_ejecucion desc, m.creado desc, m.id
    ), '[]'::jsonb)
  ) from public.mantenimientos m);
end;
$$;

revoke all on function public.ejecutores_mantenimiento() from public, anon;
revoke all on function public.exportar_mantenimientos() from public, anon;
revoke all on function public.registrar_mantenimiento(uuid, uuid, date, text, boolean, integer) from public, anon;
grant execute on function public.ejecutores_mantenimiento() to authenticated;
grant execute on function public.exportar_mantenimientos() to authenticated;
grant execute on function public.registrar_mantenimiento(uuid, uuid, date, text, boolean, integer) to authenticated;

notify pgrst, 'reload schema';
commit;
