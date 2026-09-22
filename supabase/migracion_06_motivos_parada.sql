begin;

create table if not exists public.motivos_parada (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique
    check (nombre = btrim(nombre) and char_length(nombre) between 1 and 120),
  activo boolean not null default true,
  orden integer not null default 100,
  creado timestamptz not null default now()
);

-- IDs estables: repetir la migración no revierte nombres, orden ni bajas.
insert into public.motivos_parada(id, nombre, orden) values
('06000000-0000-4000-8000-000000000001','Logística',10),
('06000000-0000-4000-8000-000000000002','Almuerzo/descanso',20),
('06000000-0000-4000-8000-000000000003','Sanitario',30),
('06000000-0000-4000-8000-000000000004','Acondicionamiento de máquina',40),
('06000000-0000-4000-8000-000000000005','Otras',50)
on conflict do nothing;

alter table public.tarea_pausas
  add column if not exists motivo_id uuid
  references public.motivos_parada(id) on delete restrict;

-- Conservar también cualquier motivo histórico adicional.
insert into public.motivos_parada(nombre)
select distinct motivo from public.tarea_pausas where motivo_id is null
on conflict (nombre) do nothing;

update public.tarea_pausas p set motivo_id = m.id
from public.motivos_parada m
where p.motivo_id is null and m.nombre = p.motivo;

alter table public.tarea_pausas alter column motivo_id set not null;
create index if not exists idx_pausas_motivo on public.tarea_pausas(motivo_id);

-- Quitar la lista fija de cinco textos de la migración 04.
alter table public.tarea_pausas
  drop constraint if exists tarea_pausas_motivo_check;

alter table public.motivos_parada enable row level security;
drop policy if exists motivos_lectura on public.motivos_parada;
create policy motivos_lectura on public.motivos_parada
  for select to authenticated
  using (public.rango(public.rol_actual()) >= 1);
drop policy if exists motivos_admin on public.motivos_parada;
create policy motivos_admin on public.motivos_parada
  for all to authenticated
  using (public.rol_actual() = 'admin')
  with check (public.rol_actual() = 'admin');
revoke all on public.motivos_parada from public, anon;
grant select, insert, update, delete on public.motivos_parada to authenticated;

create or replace function public.gestionar_tarea(
  p_accion text,
  p_tarea uuid default null,
  p_pedido uuid default null,
  p_actividad text default null,
  p_motivo text default null,
  p_ok integer default null,
  p_scrap integer default null,
  p_observaciones text default '',
  p_revision integer default null
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_t public.tareas%rowtype;
  v_p public.pedidos%rowtype;
  v_a public.articulos%rowtype;
  v_pausa public.tarea_pausas%rowtype;
  v_ahora timestamptz;
  v_id uuid;
  v_std numeric;
  v_motivo_id uuid;
begin
  -- El perfil serializa solicitudes de un mismo operario, incluso al iniciar.
  perform 1 from public.perfiles
    where id = v_uid and activo and rol in ('operario','supervisor','admin')
    for update;
  if not found then raise exception 'Sesión inválida o cuenta inactiva'; end if;

  if p_accion = 'iniciar' then
    if exists (select 1 from public.tareas
               where operario_id = v_uid and not confirmada) then
      raise exception 'Ya tenés una tarea pendiente';
    end if;
    select * into v_p from public.pedidos where id = p_pedido for no key update;
    if not found then raise exception 'La orden no existe'; end if;
    if v_p.estado = 'finalizado' then raise exception 'La orden ya está finalizada'; end if;
    select * into v_a from public.articulos where id = v_p.articulo_id;
    v_std := case p_actividad
      when 'inyectado' then v_a.std_inyectado
      when 'rebabado' then v_a.std_rebabado
      when 'armado' then v_a.std_armado
      when 'embolsado' then v_a.std_embolsado end;
    if not v_a.activo or coalesce(v_std, 0) <= 0 then
      raise exception 'El artículo o la actividad no están habilitados';
    end if;
    insert into public.tareas(pedido_id, actividad, operario_id, inicio)
      values(p_pedido, p_actividad, v_uid, clock_timestamp()) returning id into v_id;
    return v_id;
  end if;

  select * into v_t from public.tareas
    where id = p_tarea and operario_id = v_uid for update;
  if not found then raise exception 'La tarea no existe o no te pertenece'; end if;
  if v_t.confirmada then raise exception 'La tarea ya está registrada'; end if;
  if p_revision is distinct from v_t.revision then
    raise exception 'La tarea cambió en otra sesión. Se actualizará la pantalla';
  end if;
  perform 1 from public.pedidos where id = v_t.pedido_id for no key update;
  -- Se toma después de esperar los bloqueos, no al comienzo de la transacción.
  v_ahora := clock_timestamp();
  select * into v_pausa from public.tarea_pausas
    where tarea_id = v_t.id and fin is null;

  if p_accion = 'pausar' then
    if v_t.fin is not null or v_pausa.id is not null then
      raise exception 'La tarea no está trabajando';
    end if;
    select id into v_motivo_id from public.motivos_parada
      where nombre = p_motivo and activo
      for share;
    if not found then
      raise exception 'El motivo cambió o está inactivo. Actualizá los motivos y elegí otro';
    end if;
    -- Conservar el texto que se eligió y el ID permanente del catálogo.
    insert into public.tarea_pausas(tarea_id, motivo_id, motivo, inicio)
      values(v_t.id, v_motivo_id, p_motivo, clock_timestamp());
  elsif p_accion = 'reanudar' then
    if v_t.fin is not null or v_pausa.id is null then
      raise exception 'La tarea no está pausada';
    end if;
    update public.tarea_pausas set fin = v_ahora where id = v_pausa.id;
  elsif p_accion = 'finalizar' then
    if v_t.fin is not null then raise exception 'La tarea ya está finalizada'; end if;
    update public.tarea_pausas set fin = v_ahora where id = v_pausa.id;
    update public.tareas set fin = v_ahora where id = v_t.id;
  elsif p_accion = 'confirmar' then
    if v_t.fin is null or v_pausa.id is not null then
      raise exception 'Primero finalizá la tarea';
    end if;
    if p_ok is null or p_scrap is null or p_ok < 0 or p_scrap < 0 then
      raise exception 'Las cantidades deben ser enteros no negativos';
    end if;
    if char_length(coalesce(p_observaciones, '')) > 2000 then
      raise exception 'Las observaciones admiten hasta 2000 caracteres';
    end if;
    if p_ok = 0 and p_scrap = 0 and btrim(coalesce(p_observaciones, '')) = '' then
      raise exception 'Explicá en observaciones por qué no hubo producción';
    end if;
    update public.tareas set piezas_ok = p_ok, piezas_scrap = p_scrap,
      observaciones = btrim(coalesce(p_observaciones, '')), confirmada = true
      where id = v_t.id;
  elsif p_accion = 'descartar' then
    -- Preservar tiempos y pausas: registrar con cero piezas y una observación.
    raise exception 'Registrá la tarea con cero piezas y explicá el motivo';
  else
    raise exception 'Acción no válida';
  end if;
  update public.tareas set revision = revision + 1 where id = v_t.id;
  return v_t.id;
end $$;

revoke all on function public.gestionar_tarea(text,uuid,uuid,text,text,integer,integer,text,integer)
  from public, anon;
grant execute on function public.gestionar_tarea(text,uuid,uuid,text,text,integer,integer,text,integer)
  to authenticated;
notify pgrst, 'reload schema';
commit;

