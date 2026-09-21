-- Aplicar sobre schema.sql actual o migraciones 01 a 03 ya aplicadas.
begin;

-- No resolver duplicados históricos automáticamente: revisar cantidades primero.
do $$ begin
  if exists (select 1 from public.tareas where not confirmada
             group by operario_id having count(*) > 1) then
    raise exception 'Hay operarios con varias tareas sin confirmar. Revisarlas antes de migrar.';
  end if;
end $$;

alter table public.tareas
  add column if not exists observaciones text not null default '',
  add column if not exists revision integer not null default 0;

create unique index if not exists uq_tarea_pendiente_por_operario
  on public.tareas(operario_id) where not confirmada;

create table if not exists public.tarea_pausas (
  id uuid primary key default gen_random_uuid(),
  tarea_id uuid not null references public.tareas(id) on delete cascade,
  motivo text not null check (motivo in (
    'Logística', 'Almuerzo/descanso', 'Sanitario',
    'Acondicionamiento de máquina', 'Otras')),
  inicio timestamptz not null,
  fin timestamptz,
  check (fin is null or fin >= inicio)
);
create index if not exists idx_pausas_tarea on public.tarea_pausas(tarea_id);
create unique index if not exists uq_pausa_abierta
  on public.tarea_pausas(tarea_id) where fin is null;
alter table public.tarea_pausas enable row level security;
drop policy if exists pausas_select on public.tarea_pausas;
create policy pausas_select on public.tarea_pausas for select to authenticated
  using (public.rango(public.rol_actual()) >= 1);

-- Los supervisores necesitan identificar a los operarios en el historial.
drop policy if exists perfiles_select on public.perfiles;
create policy perfiles_select on public.perfiles for select to authenticated
  using (id = auth.uid() or public.rango(public.rol_actual()) >= 2);

-- Mantener columnas anteriores en su mismo orden y tipo; agregar las nuevas al final.
create or replace view public.v_tareas with (security_invoker = on) as
select t.id, t.pedido_id, p.codigo as pedido_codigo, p.articulo_id,
       a.nombre as articulo_nombre, t.actividad,
       coalesce(pe.nombre, '—') as operario_nombre, t.operario_id,
       t.inicio, t.fin, t.piezas_ok, t.piezas_scrap, t.creado, t.confirmada,
       case when t.fin is null then null else
         greatest(0, floor(extract(epoch from (t.fin - t.inicio))
                          - pausas.segundos))::int end as real_seg,
       (t.piezas_ok * (case t.actividad
          when 'inyectado' then a.std_inyectado
          when 'rebabado' then a.std_rebabado
          when 'armado' then a.std_armado
          when 'embolsado' then a.std_embolsado end))::numeric as std_seg,
       t.observaciones, t.revision,
       greatest(0, floor(extract(epoch from
         (coalesce(t.fin, statement_timestamp()) - t.inicio))))::int as total_seg,
       greatest(0, floor(pausas.segundos))::int as pausa_seg,
       abierta.id as pausa_id, abierta.inicio as pausa_inicio,
       abierta.motivo as pausa_motivo,
       statement_timestamp() as servidor_ahora
from public.tareas t
join public.pedidos p on p.id = t.pedido_id
join public.articulos a on a.id = p.articulo_id
left join public.perfiles pe on pe.id = t.operario_id
left join lateral (
  select coalesce(sum(extract(epoch from
    (coalesce(x.fin, t.fin, statement_timestamp()) - x.inicio))), 0) as segundos
  from public.tarea_pausas x where x.tarea_id = t.id
) pausas on true
left join public.tarea_pausas abierta
  on abierta.tarea_id = t.id and abierta.fin is null;

-- Bloquear la orden ANTES de calcular su avance. Cada consulta posterior
-- ve las confirmaciones ya comprometidas al usar READ COMMITTED.
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_meta int; v_av int; v_bruto int;
begin
  select cantidad into v_meta from public.pedidos
    where id = v_pedido for no key update;
  select a.avance, a.bruto into v_av, v_bruto
    from public.avance_pedido(v_pedido) a;
  update public.pedidos set estado = case
    when v_meta > 0 and v_av >= v_meta then 'finalizado'
    when coalesce(v_bruto, 0) > 0 then 'en_curso'
    else 'pendiente' end
    where id = v_pedido;
  return null;
end $$;

-- Una RPC hace cada transición de manera atómica, con horario del servidor.
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
    if p_motivo is null or p_motivo not in (
      'Logística','Almuerzo/descanso','Sanitario',
      'Acondicionamiento de máquina','Otras') then
      raise exception 'Seleccioná un motivo válido';
    end if;
    insert into public.tarea_pausas(tarea_id, motivo, inicio)
      values(v_t.id, p_motivo, v_ahora);
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

-- El navegador sólo lee tablas. Escribir exige pasar por la RPC validada.
revoke insert, update, delete, truncate, references, trigger
  on public.tareas, public.tarea_pausas from public, anon, authenticated;
grant select on public.tareas, public.tarea_pausas, public.v_tareas to authenticated;
revoke all on function public.gestionar_tarea(text,uuid,uuid,text,text,integer,integer,text,integer)
  from public, anon;
grant execute on function public.gestionar_tarea(text,uuid,uuid,text,text,integer,integer,text,integer)
  to authenticated;
notify pgrst, 'reload schema';
commit;
