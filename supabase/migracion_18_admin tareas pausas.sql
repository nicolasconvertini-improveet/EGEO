-- Aplicar DESPUÉS de la migración 17.
-- El administrador puede corregir o eliminar tareas ya registradas (confirmadas)
-- y sus pausas. Cada cambio pide un motivo y queda en tarea_auditoria.
begin;

-- 1) Auditoría de correcciones -------------------------------------------
create table if not exists public.tarea_auditoria (
  id bigint generated always as identity primary key,
  tarea_id uuid not null,              -- sin FK: la tarea puede haberse eliminado
  pausa_id uuid,
  accion text not null check (accion in ('editar_tarea','eliminar_tarea','editar_pausa','eliminar_pausa')),
  antes jsonb,
  despues jsonb,
  motivo text not null check (char_length(btrim(motivo)) between 3 and 500),
  usuario_id uuid not null,
  usuario_nombre text,
  creado timestamptz not null default now()
);
create index if not exists idx_tarea_auditoria_tarea on public.tarea_auditoria(tarea_id);

alter table public.tarea_auditoria enable row level security;
drop policy if exists sesion_obligatoria on public.tarea_auditoria;
create policy sesion_obligatoria on public.tarea_auditoria as restrictive for all to authenticated
  using ((select egeo_privado.sesion_activa())) with check ((select egeo_privado.sesion_activa()));
drop policy if exists auditoria_lectura on public.tarea_auditoria;
create policy auditoria_lectura on public.tarea_auditoria for select to authenticated
  using (public.rol_actual() = 'admin');
revoke all on public.tarea_auditoria from public, anon, authenticated;
grant select on public.tarea_auditoria to authenticated;

-- 2) Validación común: sesión + administrador activo ----------------------
create or replace function egeo_privado.exigir_admin(p_motivo text)
returns public.perfiles language plpgsql security definer set search_path = '' as $$
declare v_u public.perfiles%rowtype;
begin
  perform public.validar_sesion();
  select * into v_u from public.perfiles where id = auth.uid() and activo and rol = 'admin';
  if not found then
    raise exception 'Sólo un administrador activo puede corregir tareas' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'Indicá el motivo de la corrección (mínimo 3 caracteres)' using errcode = '22023';
  end if;
  return v_u;
end $$;
revoke all on function egeo_privado.exigir_admin(text) from public, anon;
grant execute on function egeo_privado.exigir_admin(text) to authenticated;

-- 3) Editar tarea -----------------------------------------------------------
create or replace function public.admin_editar_tarea(
  p_tarea uuid, p_revision integer, p_inicio timestamptz, p_fin timestamptz,
  p_ok integer, p_scrap integer, p_observaciones text, p_motivo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles%rowtype := egeo_privado.exigir_admin(p_motivo);
  v_t public.tareas%rowtype;
  v_nueva public.tareas%rowtype;
begin
  select * into v_t from public.tareas where id = p_tarea for update;
  if not found then raise exception 'La tarea no existe'; end if;
  if not v_t.confirmada then raise exception 'Sólo se corrigen tareas ya registradas'; end if;
  if p_revision is distinct from v_t.revision then
    raise exception 'La tarea cambió mientras la editabas. Volvé a abrirla';
  end if;
  if p_inicio is null or p_fin is null or p_fin <= p_inicio then
    raise exception 'El fin debe ser posterior al inicio';
  end if;
  if p_fin > clock_timestamp() then raise exception 'El fin no puede ser futuro'; end if;
  if p_ok is null or p_scrap is null or p_ok < 0 or p_scrap < 0 then
    raise exception 'Las cantidades deben ser enteros no negativos';
  end if;
  if char_length(coalesce(p_observaciones, '')) > 2000 then
    raise exception 'Las observaciones admiten hasta 2000 caracteres';
  end if;
  if p_ok = 0 and p_scrap = 0 and btrim(coalesce(p_observaciones, '')) = '' then
    raise exception 'Sin piezas, las observaciones son obligatorias';
  end if;
  if exists (select 1 from public.tarea_pausas
             where tarea_id = v_t.id and (inicio < p_inicio or fin > p_fin)) then
    raise exception 'Hay pausas fuera del nuevo horario. Ajustalas o eliminálas primero';
  end if;
  if exists (select 1 from public.tareas
             where operario_id = v_t.operario_id and id <> v_t.id
               and inicio < p_fin and coalesce(fin, clock_timestamp()) > p_inicio) then
    raise exception 'El nuevo horario se superpone con otra tarea del mismo operario';
  end if;

  perform 1 from public.pedidos where id = v_t.pedido_id for no key update;
  update public.tareas set inicio = p_inicio, fin = p_fin, piezas_ok = p_ok,
    piezas_scrap = p_scrap, observaciones = btrim(coalesce(p_observaciones, '')),
    revision = revision + 1
    where id = v_t.id returning * into v_nueva;

  insert into public.tarea_auditoria(tarea_id, accion, antes, despues, motivo, usuario_id, usuario_nombre)
    values (v_t.id, 'editar_tarea', to_jsonb(v_t), to_jsonb(v_nueva), btrim(p_motivo), v_u.id, v_u.nombre);
  return to_jsonb(v_nueva);
end $$;

-- 4) Eliminar tarea (borra sus pausas por ON DELETE CASCADE) ---------------
create or replace function public.admin_eliminar_tarea(p_tarea uuid, p_revision integer, p_motivo text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles%rowtype := egeo_privado.exigir_admin(p_motivo);
  v_t public.tareas%rowtype;
  v_pausas jsonb;
begin
  select * into v_t from public.tareas where id = p_tarea for update;
  if not found then raise exception 'La tarea no existe'; end if;
  if not v_t.confirmada then raise exception 'Sólo se eliminan tareas ya registradas'; end if;
  if p_revision is distinct from v_t.revision then
    raise exception 'La tarea cambió mientras la editabas. Volvé a abrirla';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.inicio), '[]'::jsonb) into v_pausas
    from public.tarea_pausas x where x.tarea_id = v_t.id;

  perform 1 from public.pedidos where id = v_t.pedido_id for no key update;
  insert into public.tarea_auditoria(tarea_id, accion, antes, motivo, usuario_id, usuario_nombre)
    values (v_t.id, 'eliminar_tarea', to_jsonb(v_t) || jsonb_build_object('pausas', v_pausas),
            btrim(p_motivo), v_u.id, v_u.nombre);
  delete from public.tareas where id = v_t.id;   -- el trigger recalcula el estado de la orden
  return v_t.id;
end $$;

-- 5) Editar pausa -----------------------------------------------------------
create or replace function public.admin_editar_pausa(
  p_pausa uuid, p_inicio timestamptz, p_fin timestamptz, p_motivo_id uuid, p_motivo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles%rowtype := egeo_privado.exigir_admin(p_motivo);
  v_p public.tarea_pausas%rowtype;
  v_t public.tareas%rowtype;
  v_nombre text;
  v_nueva public.tarea_pausas%rowtype;
begin
  select * into v_p from public.tarea_pausas where id = p_pausa for update;
  if not found then raise exception 'La pausa no existe'; end if;
  select * into v_t from public.tareas where id = v_p.tarea_id for update;
  if not v_t.confirmada then raise exception 'Sólo se corrigen pausas de tareas ya registradas'; end if;
  if p_inicio is null or p_fin is null or p_fin < p_inicio then
    raise exception 'El fin de la pausa debe ser posterior al inicio';
  end if;
  if p_inicio < v_t.inicio or p_fin > v_t.fin then
    raise exception 'La pausa debe quedar dentro del horario de la tarea (% a %)',
      to_char(v_t.inicio at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI:SS'),
      to_char(v_t.fin at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI:SS');
  end if;
  if exists (select 1 from public.tarea_pausas
             where tarea_id = v_t.id and id <> v_p.id and inicio < p_fin and fin > p_inicio) then
    raise exception 'La pausa se superpone con otra pausa de la misma tarea';
  end if;
  select nombre into v_nombre from public.motivos_parada where id = p_motivo_id;
  if not found then raise exception 'El motivo de parada no existe'; end if;

  update public.tarea_pausas set inicio = p_inicio, fin = p_fin,
    motivo_id = p_motivo_id, motivo = v_nombre
    where id = v_p.id returning * into v_nueva;
  update public.tareas set revision = revision + 1 where id = v_t.id;

  insert into public.tarea_auditoria(tarea_id, pausa_id, accion, antes, despues, motivo, usuario_id, usuario_nombre)
    values (v_t.id, v_p.id, 'editar_pausa', to_jsonb(v_p), to_jsonb(v_nueva), btrim(p_motivo), v_u.id, v_u.nombre);
  return to_jsonb(v_nueva);
end $$;

-- 6) Eliminar pausa ---------------------------------------------------------
create or replace function public.admin_eliminar_pausa(p_pausa uuid, p_motivo text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_u public.perfiles%rowtype := egeo_privado.exigir_admin(p_motivo);
  v_p public.tarea_pausas%rowtype;
  v_t public.tareas%rowtype;
begin
  select * into v_p from public.tarea_pausas where id = p_pausa for update;
  if not found then raise exception 'La pausa no existe'; end if;
  select * into v_t from public.tareas where id = v_p.tarea_id for update;
  if not v_t.confirmada then raise exception 'Sólo se eliminan pausas de tareas ya registradas'; end if;

  insert into public.tarea_auditoria(tarea_id, pausa_id, accion, antes, motivo, usuario_id, usuario_nombre)
    values (v_t.id, v_p.id, 'eliminar_pausa', to_jsonb(v_p), btrim(p_motivo), v_u.id, v_u.nombre);
  delete from public.tarea_pausas where id = v_p.id;
  update public.tareas set revision = revision + 1 where id = v_t.id;
  return v_p.id;
end $$;

-- 7) Permisos: sólo usuarios autenticados (la función valida que sea admin)
do $$ declare f text; begin
  foreach f in array array[
    'public.admin_editar_tarea(uuid,integer,timestamptz,timestamptz,integer,integer,text,text)',
    'public.admin_eliminar_tarea(uuid,integer,text)',
    'public.admin_editar_pausa(uuid,timestamptz,timestamptz,uuid,text)',
    'public.admin_eliminar_pausa(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;