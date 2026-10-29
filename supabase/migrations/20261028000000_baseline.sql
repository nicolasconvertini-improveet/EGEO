-- Origen: schema.sql
-- =====================================================================
--  App de productividad — esquema Supabase (Postgres)
--  Ejecutar en:  Supabase → SQL Editor → New query → pegar → Run
--  Es idempotente: se puede correr más de una vez sin romper nada.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) PERFILES  (extiende auth.users con nombre y rol)
--    Jerarquía acumulativa: operario < supervisor < admin
-- ---------------------------------------------------------------------
create table if not exists public.perfiles (
  id      uuid primary key references auth.users(id) on delete cascade,
  nombre  text not null default '',
  rol     text not null default 'operario'
          check (rol in ('operario','supervisor','admin')),
  activo  boolean not null default true,
  creado  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2) ARTICULOS  (maestro + tiempo estándar por unidad de cada tarea)
-- ---------------------------------------------------------------------
create table if not exists public.articulos (
  id             uuid primary key default gen_random_uuid(),
  codigo         text unique not null,
  nombre         text not null,
  molde          text,
  maquina        text,
  bocas          int,
  material       text,
  categoria      text,
  activo         boolean not null default true,
  std_inyectado  numeric not null default 0,   -- segundos / unidad
  std_rebabado   numeric not null default 0,
  std_armado     numeric not null default 0,
  std_embolsado  numeric not null default 0,
  creado         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3) PEDIDOS  (artículo + cantidad a fabricar)
-- ---------------------------------------------------------------------
create table if not exists public.pedidos (
  id          uuid primary key default gen_random_uuid(),
  codigo      text unique not null,               -- código de orden (manual y obligatorio)
  articulo_id uuid not null references public.articulos(id),
  cantidad    int  not null check (cantidad > 0),
  estado      text not null default 'pendiente'
              check (estado in ('pendiente','en_curso','finalizado')),
  creado_por  uuid references auth.users(id) default auth.uid(),
  creado      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4) TAREAS  (registro de trabajo: actividad, inicio/fin, ok, scrap)
-- ---------------------------------------------------------------------
create table if not exists public.tareas (
  id           uuid primary key default gen_random_uuid(),
  pedido_id    uuid not null references public.pedidos(id) on delete cascade,
  actividad    text not null
               check (actividad in ('inyectado','rebabado','armado','embolsado')),
  operario_id  uuid references auth.users(id) default auth.uid(),
  inicio       timestamptz not null,
  fin          timestamptz,                       -- vacío mientras la tarea está abierta
  piezas_ok    int not null default 0,
  piezas_scrap int not null default 0,
  confirmada   boolean not null default false,    -- true cuando se cargaron las piezas
  creado       timestamptz not null default now()
);

create index if not exists idx_articulos_categoria on public.articulos(categoria);
create index if not exists idx_tareas_pedido on public.tareas(pedido_id);
create index if not exists idx_pedidos_estado on public.pedidos(estado);

-- un operario no puede tener más de una tarea abierta a la vez
create unique index if not exists uq_tarea_abierta_por_operario
  on public.tareas (operario_id) where fin is null;

-- =====================================================================
--  FUNCIONES AUXILIARES (para las políticas de seguridad)
-- =====================================================================

-- rol del usuario actual (security definer: puede leer perfiles sin recursión de RLS)
create or replace function public.rol_actual()
returns text language sql stable security definer set search_path = public as $$
  select rol from public.perfiles where id = auth.uid() and activo = true;
$$;

-- rango numérico del rol, para comparaciones "de este rol para arriba"
create or replace function public.rango(r text)
returns int language sql immutable as $$
  select case r
    when 'admin' then 3
    when 'supervisor' then 2
    when 'operario' then 1
    else 0 end;
$$;

-- alta automática de perfil cuando se crea un usuario en Auth
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, nombre, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
    'operario'
  )
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- avance del pedido: una pieza está completa cuando pasó por todas las
-- etapas que el artículo requiere (las que tienen tiempo estándar > 0),
-- por eso el avance es el de la etapa más atrasada.
create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_meta int; v_std jsonb; k text; v_ok int;
  v_min int := null; v_sum int := 0; v_req int := 0; v_comp int := 0;
begin
  select p.cantidad,
         jsonb_build_object(
           'inyectado', a.std_inyectado, 'rebabado', a.std_rebabado,
           'armado',    a.std_armado,    'embolsado', a.std_embolsado)
    into v_meta, v_std
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
   where p.id = p_pedido;

  if v_meta is null then return; end if;

  for k in select jsonb_object_keys(v_std) loop
    if coalesce((v_std->>k)::numeric, 0) > 0 then
      select coalesce(sum(piezas_ok), 0)::int into v_ok
        from public.tareas
       where pedido_id = p_pedido and actividad = k and confirmada = true;
      v_req := v_req + 1;
      v_sum := v_sum + v_ok;
      if v_min is null or v_ok < v_min then v_min := v_ok; end if;
      if v_ok >= v_meta then v_comp := v_comp + 1; end if;
    end if;
  end loop;

  if v_req = 0 then
    select coalesce(sum(piezas_ok), 0)::int into v_sum
      from public.tareas where pedido_id = p_pedido and confirmada = true;
    v_min := v_sum;
  end if;

  avance := coalesce(v_min, 0); bruto := v_sum;
  etapas_req := v_req; etapas_completas := v_comp;
  return next;
end; $$;

-- el estado del pedido depende de la etapa más atrasada
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_meta int; v_av int; v_bruto int;
begin
  select cantidad into v_meta from public.pedidos where id = v_pedido;
  select a.avance, a.bruto into v_av, v_bruto from public.avance_pedido(v_pedido) a;
  update public.pedidos
     set estado = case
       when v_meta > 0 and v_av >= v_meta then 'finalizado'
       when coalesce(v_bruto, 0) > 0      then 'en_curso'
       else 'pendiente' end
   where id = v_pedido;
  return null;
end; $$;

drop trigger if exists trg_estado_pedido on public.tareas;
create trigger trg_estado_pedido
  after insert or update or delete on public.tareas
  for each row execute function public.recalcular_estado_pedido();

-- =====================================================================
--  VISTAS (avance de pedidos y tareas con datos relacionados)
--  security_invoker = respetan las políticas RLS de quien consulta
-- =====================================================================
drop view if exists public.v_pedido_etapas;
drop view if exists public.v_tareas;
drop view if exists public.v_pedidos;

create or replace view public.v_pedidos with (security_invoker = on) as
  select p.id, p.codigo, p.articulo_id,
         a.nombre as articulo_nombre, a.codigo as articulo_codigo,
         p.cantidad, p.estado, p.creado,
         av.avance           as ok_acum,
         av.bruto            as ok_bruto,
         av.etapas_req       as etapas_req,
         av.etapas_completas as etapas_completas,
         coalesce((select sum(t.piezas_scrap)::int
                     from public.tareas t
                    where t.pedido_id = p.id and t.confirmada), 0) as scrap_acum
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
    left join lateral public.avance_pedido(p.id) av on true;

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

-- totales por etapa de cada pedido (siempre las 4 actividades, en cero si no hubo)
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

-- =====================================================================
--  ROW LEVEL SECURITY
--  Regla general de lectura: hay que tener perfil activo (rango >= 1).
--  Escrituras: según el rol mínimo requerido.
-- =====================================================================
alter table public.perfiles  enable row level security;
alter table public.articulos enable row level security;
alter table public.pedidos   enable row level security;
alter table public.tareas    enable row level security;

-- ---- PERFILES ----
drop policy if exists perfiles_select on public.perfiles;
create policy perfiles_select on public.perfiles for select
  using (id = auth.uid() or public.rol_actual() = 'admin');

drop policy if exists perfiles_admin_write on public.perfiles;
create policy perfiles_admin_write on public.perfiles for all
  using (public.rol_actual() = 'admin')
  with check (public.rol_actual() = 'admin');

-- ---- ARTICULOS ----  (todos leen; sólo admin escribe)
drop policy if exists articulos_select on public.articulos;
create policy articulos_select on public.articulos for select
  using (public.rango(public.rol_actual()) >= 1);

drop policy if exists articulos_admin_write on public.articulos;
create policy articulos_admin_write on public.articulos for all
  using (public.rol_actual() = 'admin')
  with check (public.rol_actual() = 'admin');

-- ---- PEDIDOS ----  (todos leen; supervisor+ crea/edita; admin borra)
drop policy if exists pedidos_select on public.pedidos;
create policy pedidos_select on public.pedidos for select
  using (public.rango(public.rol_actual()) >= 1);

drop policy if exists pedidos_insert on public.pedidos;
create policy pedidos_insert on public.pedidos for insert
  with check (public.rango(public.rol_actual()) >= 2);

drop policy if exists pedidos_update on public.pedidos;
create policy pedidos_update on public.pedidos for update
  using (public.rango(public.rol_actual()) >= 2);

drop policy if exists pedidos_delete on public.pedidos;
create policy pedidos_delete on public.pedidos for delete
  using (public.rol_actual() = 'admin');

-- ---- TAREAS ----  (todos leen; operario+ inserta las propias; edita propias o supervisor+)
drop policy if exists tareas_select on public.tareas;
create policy tareas_select on public.tareas for select
  using (public.rango(public.rol_actual()) >= 1);

drop policy if exists tareas_insert on public.tareas;
create policy tareas_insert on public.tareas for insert
  with check (public.rango(public.rol_actual()) >= 1 and operario_id = auth.uid());

drop policy if exists tareas_update on public.tareas;
create policy tareas_update on public.tareas for update
  using (operario_id = auth.uid() or public.rango(public.rol_actual()) >= 2);

drop policy if exists tareas_delete on public.tareas;
create policy tareas_delete on public.tareas for delete
  using (public.rango(public.rol_actual()) >= 2);

-- =====================================================================
--  LISTO. Después de correr esto:
--  1) Crear tu usuario (registrándote desde la app o en Auth → Users).
--  2) Convertirte en admin con:
--       update public.perfiles set rol = 'admin'
--       where id = (select id from auth.users where email = 'TU_EMAIL');
--  3) (Opcional) Cargar artículos de ejemplo con supabase/seed.sql
-- =====================================================================

-- Origen: migracion_01.sql
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


-- Origen: migracion_02.sql
-- =====================================================================
--  Migración 02 — el pedido se completa sólo cuando TODAS las etapas
--  aplicables alcanzan la cantidad pedida.
--
--  Una pieza se considera terminada cuando pasó por todos los procesos
--  que el artículo requiere (los que tienen tiempo estándar mayor a 0).
--  Por eso el avance del pedido es el de la ETAPA MÁS ATRASADA.
--
--  Ejecutar en: Supabase → SQL Editor → New query → Run
--  Es idempotente y no borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Función de avance
--    Devuelve:
--      avance           = piezas completas (mínimo entre las etapas requeridas)
--      bruto            = suma de piezas de todas las etapas (volumen trabajado)
--      etapas_req       = cuántas etapas requiere el artículo
--      etapas_completas = cuántas ya alcanzaron la cantidad pedida
-- ---------------------------------------------------------------------
create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_meta  int;
  v_std   jsonb;
  k       text;
  v_ok    int;
  v_min   int := null;
  v_sum   int := 0;
  v_req   int := 0;
  v_comp  int := 0;
begin
  select p.cantidad,
         jsonb_build_object(
           'inyectado', a.std_inyectado, 'rebabado', a.std_rebabado,
           'armado',    a.std_armado,    'embolsado', a.std_embolsado)
    into v_meta, v_std
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
   where p.id = p_pedido;

  if v_meta is null then
    return;
  end if;

  -- recorre las cuatro etapas y considera sólo las que el artículo usa
  for k in select jsonb_object_keys(v_std) loop
    if coalesce((v_std->>k)::numeric, 0) > 0 then
      select coalesce(sum(piezas_ok), 0)::int into v_ok
        from public.tareas
       where pedido_id = p_pedido and actividad = k and confirmada = true;

      v_req := v_req + 1;
      v_sum := v_sum + v_ok;
      if v_min is null or v_ok < v_min then v_min := v_ok; end if;
      if v_ok >= v_meta then v_comp := v_comp + 1; end if;
    end if;
  end loop;

  -- si el artículo no tiene ningún estándar cargado, se toma el total
  if v_req = 0 then
    select coalesce(sum(piezas_ok), 0)::int into v_sum
      from public.tareas where pedido_id = p_pedido and confirmada = true;
    v_min := v_sum;
  end if;

  avance := coalesce(v_min, 0);
  bruto := v_sum;
  etapas_req := v_req;
  etapas_completas := v_comp;
  return next;
end; $$;

-- ---------------------------------------------------------------------
-- 2) El estado del pedido pasa a depender de la etapa más atrasada
-- ---------------------------------------------------------------------
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_meta   int;
  v_av     int;
  v_bruto  int;
begin
  select cantidad into v_meta from public.pedidos where id = v_pedido;
  select a.avance, a.bruto into v_av, v_bruto from public.avance_pedido(v_pedido) a;

  update public.pedidos
     set estado = case
       when v_meta > 0 and v_av >= v_meta then 'finalizado'
       when coalesce(v_bruto, 0) > 0      then 'en_curso'
       else 'pendiente' end
   where id = v_pedido;
  return null;
end; $$;

-- ---------------------------------------------------------------------
-- 3) La vista de pedidos informa el avance real y el detalle de etapas
-- ---------------------------------------------------------------------
drop view if exists public.v_pedidos;

create or replace view public.v_pedidos with (security_invoker = on) as
  select p.id, p.codigo, p.articulo_id,
         a.nombre as articulo_nombre, a.codigo as articulo_codigo,
         p.cantidad, p.estado, p.creado,
         av.avance           as ok_acum,           -- piezas completas
         av.bruto            as ok_bruto,          -- volumen total trabajado
         av.etapas_req       as etapas_req,
         av.etapas_completas as etapas_completas,
         coalesce((select sum(t.piezas_scrap)::int
                     from public.tareas t
                    where t.pedido_id = p.id and t.confirmada), 0) as scrap_acum
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
    left join lateral public.avance_pedido(p.id) av on true;

-- ---------------------------------------------------------------------
-- 4) Recalcular todos los pedidos existentes con el criterio nuevo
--    (corrige los que quedaron marcados como finalizados)
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_av int;
  v_bruto int;
begin
  for r in select id, cantidad from public.pedidos loop
    select a.avance, a.bruto into v_av, v_bruto from public.avance_pedido(r.id) a;
    update public.pedidos
       set estado = case
         when r.cantidad > 0 and v_av >= r.cantidad then 'finalizado'
         when coalesce(v_bruto, 0) > 0              then 'en_curso'
         else 'pendiente' end
     where id = r.id;
  end loop;
end $$;


-- Origen: migracion_03.sql
-- =====================================================================
--  Migración 03 — categoría de artículo
--  Agrega la columna "categoria" (el "Tipo" del listado) y la expone
--  en las vistas para poder filtrar por ella.
--  Ejecutar en: Supabase → SQL Editor → New query → Run. Idempotente.
-- =====================================================================

alter table public.articulos add column if not exists categoria text;

create index if not exists idx_articulos_categoria on public.articulos(categoria);

-- Origen: migracion_04_pausas.sql
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


-- Origen: migracion_05_exportacion.sql
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
    ('tarea_pausas', 'tareas', 'articulos', 'pedidos', 'perfiles') then
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


-- Origen: migracion_06_motivos_parada.sql
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



-- Origen: migracion_07_mantenimientos.sql
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


-- Origen: migracion_08_estados_sesiones.sql
-- Aplicar DESPUÉS de las migraciones 01 a 07. No ejecutar schema.sql luego.
begin;

-- Las tablas Auth no se exponen al cliente. La sesión debe existir, pertenecer
-- al JWT verificado por Supabase y no haber alcanzado su vencimiento absoluto.
create schema if not exists egeo_privado;
revoke all on schema egeo_privado from public, anon, authenticated;
grant usage on schema egeo_privado to authenticated;

create or replace function egeo_privado.sesion_activa()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_claims jsonb := auth.jwt();
begin
  return coalesce(
    auth.uid() is not null
    and (v_claims->>'exp')::numeric > extract(epoch from statement_timestamp())
    and exists (
      select 1 from auth.sessions s
      where s.id = (v_claims->>'session_id')::uuid and s.user_id = auth.uid()
        and (s.not_after is null or s.not_after > statement_timestamp())
    ) and exists (
      select 1 from public.perfiles p where p.id = auth.uid() and p.activo
        and p.rol in ('operario','supervisor','admin')
    ), false);
exception when invalid_text_representation or numeric_value_out_of_range then
  return false;
end $$;
revoke all on function egeo_privado.sesion_activa() from public, anon;
grant execute on function egeo_privado.sesion_activa() to authenticated;

create or replace function public.rol_actual()
returns text language sql stable security definer set search_path = '' as $$
  select rol from public.perfiles
  where id = auth.uid() and activo and egeo_privado.sesion_activa();
$$;

create or replace function public.validar_sesion()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not egeo_privado.sesion_activa() then
    raise exception 'Sesión vencida, cerrada o cuenta inactiva. Volvé a ingresar.' using errcode = '42501';
  end if;
  return (select jsonb_build_object('id', id, 'nombre', nombre, 'rol', rol, 'activo', activo)
          from public.perfiles where id = auth.uid());
end $$;
revoke all on function public.validar_sesion() from public, anon;
grant execute on function public.validar_sesion() to authenticated;

-- Una política restrictiva se combina con TODAS las políticas existentes,
-- incluso las que antes permitían leer el perfil propio con una sesión cerrada.
do $$ declare v_tabla text; begin
  foreach v_tabla in array array['perfiles','articulos','pedidos','tareas',
      'tarea_pausas','motivos_parada','mantenimientos'] loop
    execute format('alter table public.%I enable row level security', v_tabla);
    execute format('drop policy if exists sesion_obligatoria on public.%I', v_tabla);
    execute format('create policy sesion_obligatoria on public.%I as restrictive for all to authenticated
      using ((select egeo_privado.sesion_activa())) with check ((select egeo_privado.sesion_activa()))', v_tabla);
    execute format('revoke all on public.%I from public, anon', v_tabla);
  end loop;
end $$;
revoke all on public.v_pedidos, public.v_tareas, public.v_pedido_etapas from public, anon;

alter table public.pedidos drop constraint if exists pedidos_estado_check;
alter table public.pedidos add constraint pedidos_estado_check
  check (estado in ('pendiente','en_curso','finalizado','cancelado'));
alter table public.pedidos add column if not exists estado_revision integer not null default 0;

create table if not exists public.pedido_estado_historial (
  id uuid primary key,
  pedido_id uuid not null references public.pedidos(id) on delete restrict,
  estado_anterior text not null,
  estado_nuevo text not null,
  accion text not null check (accion in ('en_curso','cancelado','finalizado','reabrir')),
  revision_anterior integer not null,
  revision_nueva integer not null,
  usuario_id uuid not null references auth.users(id) on delete restrict,
  usuario_nombre text not null,
  usuario_rol text not null check (usuario_rol in ('supervisor','admin')),
  motivo text not null check (char_length(btrim(motivo)) between 1 and 1000),
  creado timestamptz not null default clock_timestamp()
);
create index if not exists pedido_estado_historial_orden
  on public.pedido_estado_historial(pedido_id, creado desc, id);
alter table public.pedido_estado_historial enable row level security;
revoke all on public.pedido_estado_historial from public, anon, authenticated;
grant select on public.pedido_estado_historial to authenticated;
drop policy if exists historial_lectura on public.pedido_estado_historial;
create policy historial_lectura on public.pedido_estado_historial for select to authenticated
  using (public.rol_actual() in ('admin','supervisor'));

-- Sin UPDATE directo no se puede eludir la transición ni su auditoría.
-- La creación solo acepta datos de la orden; estado y autor los pone la base.
revoke insert, update, delete on public.pedidos from public, anon, authenticated;
grant insert(codigo, articulo_id, cantidad) on public.pedidos to authenticated;
grant select on public.pedidos to authenticated;

create or replace function egeo_privado.revision_estado_pedido()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.estado is distinct from old.estado then
    new.estado_revision := old.estado_revision + 1;
  end if;
  return new;
end $$;
revoke all on function egeo_privado.revision_estado_pedido() from public, anon, authenticated;
drop trigger if exists trg_revision_estado on public.pedidos;
create trigger trg_revision_estado before update on public.pedidos
  for each row execute function egeo_privado.revision_estado_pedido();

create or replace function public.cambiar_estado_pedido(
  p_solicitud uuid, p_pedido uuid, p_revision integer, p_accion text, p_motivo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_usuario public.perfiles%rowtype;
  v_pedido public.pedidos%rowtype;
  v_historial public.pedido_estado_historial%rowtype;
  v_destino text;
begin
  perform public.validar_sesion();
  -- Mismo orden de bloqueos que gestionar_tarea: perfil y luego pedido.
  select * into v_usuario from public.perfiles where id = auth.uid() for share;
  if not v_usuario.activo or v_usuario.rol not in ('supervisor','admin') then
    raise exception 'Sólo supervisores y administradores pueden cambiar estados' using errcode = '42501';
  end if;
  if p_solicitud is null or p_pedido is null or p_revision is null or p_revision < 0
     or p_accion is null or p_accion not in ('en_curso','cancelado','finalizado','reabrir')
     or p_motivo is null or char_length(btrim(p_motivo)) not between 1 and 1000 then
    raise exception 'Indicá una acción y un motivo de 1 a 1000 caracteres' using errcode = '22023';
  end if;
  select * into v_pedido from public.pedidos where id = p_pedido for no key update;
  if not found then raise exception 'La orden no existe' using errcode = '22023'; end if;
  -- Un reintento conserva su UUID y no genera dos movimientos.
  select * into v_historial from public.pedido_estado_historial where id = p_solicitud;
  if found then
    if v_historial.pedido_id <> p_pedido or v_historial.usuario_id <> v_usuario.id
       or v_historial.accion <> p_accion or v_historial.motivo <> btrim(p_motivo)
       or v_historial.revision_anterior <> p_revision then
      raise exception 'La solicitud ya corresponde a otro cambio' using errcode = '22023';
    end if;
    return to_jsonb(v_historial);
  end if;
  if v_pedido.estado_revision <> p_revision then
    raise exception 'La orden cambió. Actualizá el estado antes de continuar.' using errcode = '40001';
  end if;
  if v_pedido.estado = 'pendiente' and p_accion in ('en_curso','cancelado') then
    v_destino := p_accion;
  elsif v_pedido.estado = 'en_curso' and p_accion = 'finalizado' then
    v_destino := 'finalizado';
  elsif v_pedido.estado = 'cancelado' and p_accion = 'reabrir' then
    v_destino := case when exists(select 1 from public.tareas where pedido_id = p_pedido)
      then 'en_curso' else 'pendiente' end;
  else
    raise exception 'Ese cambio de estado no está permitido' using errcode = '22023';
  end if;
  if v_destino in ('cancelado','finalizado') and exists (
    select 1 from public.tareas where pedido_id = p_pedido and not confirmada
  ) then
    raise exception 'Hay tareas abiertas, pausadas o pendientes de confirmar. Registralas primero.' using errcode = '22023';
  end if;
  update public.pedidos set estado = v_destino where id = p_pedido;
  insert into public.pedido_estado_historial(
    id, pedido_id, estado_anterior, estado_nuevo, accion, revision_anterior, revision_nueva,
    usuario_id, usuario_nombre, usuario_rol, motivo
  ) values (
    p_solicitud, p_pedido, v_pedido.estado, v_destino, p_accion, p_revision, p_revision + 1,
    v_usuario.id, v_usuario.nombre, v_usuario.rol, btrim(p_motivo)
  ) returning * into v_historial;
  return to_jsonb(v_historial);
end $$;
revoke all on function public.cambiar_estado_pedido(uuid,uuid,integer,text,text) from public, anon;
grant execute on function public.cambiar_estado_pedido(uuid,uuid,integer,text,text) to authenticated;

-- Mantener cierres manuales y cancelaciones. Una orden iniciada manualmente
-- no retrocede a Pendiente si todavía no se registraron piezas.
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := coalesce(new.pedido_id, old.pedido_id);
  v_p public.pedidos%rowtype;
  v_av integer;
begin
  select * into v_p from public.pedidos where id = v_id for no key update;
  if not found or v_p.estado in ('cancelado','finalizado') then return null; end if;
  select avance into v_av from public.avance_pedido(v_id);
  update public.pedidos set estado = case
    when v_p.cantidad > 0 and v_av >= v_p.cantidad then 'finalizado'
    when v_p.estado = 'en_curso' or exists(select 1 from public.tareas where pedido_id = v_id) then 'en_curso'
    else 'pendiente' end where id = v_id;
  return null;
end $$;

-- Se agrega la revisión al final para conservar columnas y dependencias.
create or replace view public.v_pedidos with (security_invoker = on) as
select p.id, p.codigo, p.articulo_id, a.nombre as articulo_nombre, a.codigo as articulo_codigo,
  p.cantidad, p.estado, p.creado, av.avance as ok_acum, av.bruto as ok_bruto,
  av.etapas_req, av.etapas_completas,
  coalesce((select sum(t.piezas_scrap)::int from public.tareas t
    where t.pedido_id = p.id and t.confirmada), 0) as scrap_acum,
  p.estado_revision
from public.pedidos p join public.articulos a on a.id = p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;

-- A continuación se redefinen explícitamente las RPC existentes para que
-- también validen sesión cuando se ejecutan con SECURITY DEFINER.
create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_meta  int;
  v_std   jsonb;
  k       text;
  v_ok    int;
  v_min   int := null;
  v_sum   int := 0;
  v_req   int := 0;
  v_comp  int := 0;
begin
  perform public.validar_sesion();
  select p.cantidad,
         jsonb_build_object(
           'inyectado', a.std_inyectado, 'rebabado', a.std_rebabado,
           'armado',    a.std_armado,    'embolsado', a.std_embolsado)
    into v_meta, v_std
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
   where p.id = p_pedido;

  if v_meta is null then
    return;
  end if;

  -- recorre las cuatro etapas y considera sólo las que el artículo usa
  for k in select jsonb_object_keys(v_std) loop
    if coalesce((v_std->>k)::numeric, 0) > 0 then
      select coalesce(sum(piezas_ok), 0)::int into v_ok
        from public.tareas
       where pedido_id = p_pedido and actividad = k and confirmada = true;

      v_req := v_req + 1;
      v_sum := v_sum + v_ok;
      if v_min is null or v_ok < v_min then v_min := v_ok; end if;
      if v_ok >= v_meta then v_comp := v_comp + 1; end if;
    end if;
  end loop;

  -- si el artículo no tiene ningún estándar cargado, se toma el total
  if v_req = 0 then
    select coalesce(sum(piezas_ok), 0)::int into v_sum
      from public.tareas where pedido_id = p_pedido and confirmada = true;
    v_min := v_sum;
  end if;

  avance := coalesce(v_min, 0);
  bruto := v_sum;
  etapas_req := v_req;
  etapas_completas := v_comp;
  return next;
end; $$;
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
  perform public.validar_sesion();
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
    if v_p.estado in ('finalizado','cancelado') then raise exception 'La orden está finalizada o cancelada'; end if;
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
  perform public.validar_sesion();
  if auth.uid() is null or not exists (
    select 1 from public.perfiles
    where id = auth.uid() and activo and rol = 'admin'
  ) then
    raise exception 'Sólo un administrador activo puede exportar datos'
      using errcode = '42501';
  end if;

  if p_tabla is null or p_tabla not in
    ('tarea_pausas', 'tareas', 'articulos', 'pedidos', 'perfiles') then
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
create or replace function public.ejecutores_mantenimiento()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.validar_sesion();
  if auth.uid() is null or public.rol_actual() not in ('admin', 'supervisor')
     or public.rol_actual() is null then
    raise exception 'Se requiere un administrador o supervisor activo' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre)
    order by nombre, id), '[]'::jsonb) from public.perfiles where activo);
end;
$$;
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
  perform public.validar_sesion();
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
create or replace function public.exportar_mantenimientos()
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'UTC'
as $$
declare v_columnas jsonb;
begin
  perform public.validar_sesion();
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
revoke all on function public.avance_pedido(uuid) from public, anon;
grant execute on function public.avance_pedido(uuid) to authenticated;
revoke all on function public.rol_actual() from public, anon;
grant execute on function public.rol_actual() to authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.recalcular_estado_pedido() from public, anon, authenticated;
notify pgrst, 'reload schema';
commit;


-- Origen: migracion_09_finalizadas_pendientes
-- Aplicar completa DESPUÉS de la migración 08. Preserva sesiones y auditoría.
begin;

alter table public.pedidos drop constraint if exists pedidos_estado_check;
alter table public.pedidos add constraint pedidos_estado_check
  check (estado in ('pendiente','en_curso','finalizado','cancelado','finalizado_pendientes'));

-- Registrar la reclasificación de órdenes existentes sin atribuirla a un usuario.
-- Las operaciones de la aplicación continúan siendo manuales y con autor.
alter table public.pedido_estado_historial
  add column if not exists origen text not null default 'manual';
alter table public.pedido_estado_historial alter column usuario_id drop not null;
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_usuario_rol_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_usuario_rol_check
  check (usuario_rol in ('supervisor','admin','sistema'));
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_accion_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_accion_check
  check (accion in ('en_curso','cancelado','finalizado','reabrir','reclasificar'));
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_origen_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_origen_check check (
  (origen = 'manual' and usuario_id is not null and usuario_rol in ('supervisor','admin')
    and accion in ('en_curso','cancelado','finalizado','reabrir'))
  or (origen = 'migracion_09' and usuario_id is null and usuario_rol = 'sistema' and accion = 'reclasificar')
);

-- El cálculo interno solo lo usan funciones del propietario y la migración.
-- La RPC pública conserva validar_sesion antes de devolver datos.
create or replace function egeo_privado.avance_pedido_interno(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_meta  int;
  v_std   jsonb;
  k       text;
  v_ok    int;
  v_min   int := null;
  v_sum   int := 0;
  v_req   int := 0;
  v_comp  int := 0;
begin

  select p.cantidad,
         jsonb_build_object(
           'inyectado', a.std_inyectado, 'rebabado', a.std_rebabado,
           'armado',    a.std_armado,    'embolsado', a.std_embolsado)
    into v_meta, v_std
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
   where p.id = p_pedido;

  if v_meta is null then
    return;
  end if;

  -- recorre las cuatro etapas y considera sólo las que el artículo usa
  for k in select jsonb_object_keys(v_std) loop
    if coalesce((v_std->>k)::numeric, 0) > 0 then
      select coalesce(sum(piezas_ok), 0)::int into v_ok
        from public.tareas
       where pedido_id = p_pedido and actividad = k and confirmada = true;

      v_req := v_req + 1;
      v_sum := v_sum + v_ok;
      if v_min is null or v_ok < v_min then v_min := v_ok; end if;
      if v_ok >= v_meta then v_comp := v_comp + 1; end if;
    end if;
  end loop;

  -- si el artículo no tiene ningún estándar cargado, se toma el total
  if v_req = 0 then
    select coalesce(sum(piezas_ok), 0)::int into v_sum
      from public.tareas where pedido_id = p_pedido and confirmada = true;
    v_min := v_sum;
  end if;

  avance := coalesce(v_min, 0);
  bruto := v_sum;
  etapas_req := v_req;
  etapas_completas := v_comp;
  return next;
end; $$;
revoke all on function egeo_privado.avance_pedido_interno(uuid) from public, anon, authenticated;

create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.validar_sesion();
  return query select * from egeo_privado.avance_pedido_interno(p_pedido);
end $$;
revoke all on function public.avance_pedido(uuid) from public, anon;
grant execute on function public.avance_pedido(uuid) to authenticated;
create or replace function public.cambiar_estado_pedido(
  p_solicitud uuid, p_pedido uuid, p_revision integer, p_accion text, p_motivo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_usuario public.perfiles%rowtype;
  v_pedido public.pedidos%rowtype;
  v_historial public.pedido_estado_historial%rowtype;
  v_destino text;
begin
  perform public.validar_sesion();
  -- Mismo orden de bloqueos que gestionar_tarea: perfil y luego pedido.
  select * into v_usuario from public.perfiles where id = auth.uid() for share;
  if not v_usuario.activo or v_usuario.rol not in ('supervisor','admin') then
    raise exception 'Sólo supervisores y administradores pueden cambiar estados' using errcode = '42501';
  end if;
  if p_solicitud is null or p_pedido is null or p_revision is null or p_revision < 0
     or p_accion is null or p_accion not in ('en_curso','cancelado','finalizado','reabrir')
     or p_motivo is null or char_length(btrim(p_motivo)) not between 1 and 1000 then
    raise exception 'Indicá una acción y un motivo de 1 a 1000 caracteres' using errcode = '22023';
  end if;
  select * into v_pedido from public.pedidos where id = p_pedido for no key update;
  if not found then raise exception 'La orden no existe' using errcode = '22023'; end if;
  -- Un reintento conserva su UUID y no genera dos movimientos.
  select * into v_historial from public.pedido_estado_historial where id = p_solicitud;
  if found then
    if v_historial.pedido_id <> p_pedido or v_historial.usuario_id <> v_usuario.id
       or v_historial.accion <> p_accion or v_historial.motivo <> btrim(p_motivo)
       or v_historial.revision_anterior <> p_revision then
      raise exception 'La solicitud ya corresponde a otro cambio' using errcode = '22023';
    end if;
    return to_jsonb(v_historial);
  end if;
  if v_pedido.estado_revision <> p_revision then
    raise exception 'La orden cambió. Actualizá el estado antes de continuar.' using errcode = '40001';
  end if;
  if v_pedido.estado = 'pendiente' and p_accion in ('en_curso','cancelado') then
    v_destino := p_accion;
  elsif v_pedido.estado = 'en_curso' and p_accion = 'finalizado' then
    v_destino := case when coalesce((select avance from public.avance_pedido(p_pedido)), 0) >= v_pedido.cantidad
      then 'finalizado' else 'finalizado_pendientes' end;
  elsif v_pedido.estado in ('cancelado','finalizado_pendientes') and p_accion = 'reabrir' then
    v_destino := case when exists(select 1 from public.tareas where pedido_id = p_pedido)
      then 'en_curso' else 'pendiente' end;
  else
    raise exception 'Ese cambio de estado no está permitido' using errcode = '22023';
  end if;
  if v_destino in ('cancelado','finalizado','finalizado_pendientes') and exists (
    select 1 from public.tareas where pedido_id = p_pedido and not confirmada
  ) then
    raise exception 'Hay tareas abiertas, pausadas o pendientes de confirmar. Registralas primero.' using errcode = '22023';
  end if;
  update public.pedidos set estado = v_destino where id = p_pedido;
  insert into public.pedido_estado_historial(
    id, pedido_id, estado_anterior, estado_nuevo, accion, revision_anterior, revision_nueva,
    usuario_id, usuario_nombre, usuario_rol, motivo
  ) values (
    p_solicitud, p_pedido, v_pedido.estado, v_destino, p_accion, p_revision, p_revision + 1,
    v_usuario.id, v_usuario.nombre, v_usuario.rol, btrim(p_motivo)
  ) returning * into v_historial;
  return to_jsonb(v_historial);
end $$;
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := coalesce(new.pedido_id, old.pedido_id);
  v_p public.pedidos%rowtype;
  v_av integer;
begin
  select * into v_p from public.pedidos where id = v_id for no key update;
  if not found or v_p.estado in ('cancelado','finalizado','finalizado_pendientes') then return null; end if;
  select avance into v_av from public.avance_pedido(v_id);
  update public.pedidos set estado = case
    when v_p.cantidad > 0 and v_av >= v_p.cantidad then 'finalizado'
    when v_p.estado = 'en_curso' or exists(select 1 from public.tareas where pedido_id = v_id) then 'en_curso'
    else 'pendiente' end where id = v_id;
  return null;
end $$;
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
  perform public.validar_sesion();
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
    if v_p.estado in ('finalizado','cancelado','finalizado_pendientes') then raise exception 'La orden está cerrada o cancelada. Reabrila antes de iniciar tareas.'; end if;
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

-- Convertir los cierres históricos incompletos una sola vez. La migración
-- conserva el evento de cierre original y agrega un evento técnico de sistema.
do $$
declare r record;
begin
  for r in
    select p.id, p.estado_revision from public.pedidos p
    cross join lateral egeo_privado.avance_pedido_interno(p.id) av
    where p.estado = 'finalizado' and av.avance < p.cantidad
  loop
    update public.pedidos set estado = 'finalizado_pendientes' where id = r.id;
    insert into public.pedido_estado_historial (
      id, pedido_id, estado_anterior, estado_nuevo, accion, revision_anterior,
      revision_nueva, usuario_id, usuario_nombre, usuario_rol, motivo, origen
    ) values (
      gen_random_uuid(), r.id, 'finalizado', 'finalizado_pendientes', 'reclasificar',
      r.estado_revision, r.estado_revision + 1, null, 'Sistema', 'sistema',
      'Migración 09: cierre existente con producción pendiente según las etapas y cantidades actuales.',
      'migracion_09'
    );
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;


-- Origen: migracion_10_historial_automatico
-- Aplicar DESPUÉS de la 09. Audita todos los cambios efectivos de estado.
-- No inventa transiciones anteriores que no fueron registradas.
begin;

-- Reservar el valor sin reescribir silenciosamente motivos históricos.
do $$ begin
  if exists (select 1 from public.pedido_estado_historial
             where origen <> 'automatico' and motivo = 'automatico') then
    raise exception 'Existe un registro histórico no automático con motivo automatico. Revisar ese historial antes de aplicar la migración 10.';
  end if;
end $$;

alter table public.pedido_estado_historial add column if not exists detalle_proceso text;
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_usuario_rol_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_usuario_rol_check
  check (usuario_rol in ('operario','supervisor','admin','sistema'));
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_accion_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_accion_check
  check (accion in ('en_curso','cancelado','finalizado','reabrir','reclasificar','automatico','sistema'));
alter table public.pedido_estado_historial drop constraint if exists pedido_estado_historial_origen_check;
alter table public.pedido_estado_historial add constraint pedido_estado_historial_origen_check check (
  (origen = 'manual' and usuario_id is not null and usuario_rol in ('supervisor','admin')
    and accion in ('en_curso','cancelado','finalizado','reabrir') and motivo <> 'automatico')
  or (origen = 'migracion_09' and usuario_id is null and usuario_rol = 'sistema'
    and accion = 'reclasificar' and motivo <> 'automatico')
  or (origen = 'automatico' and accion = 'automatico' and motivo = 'automatico'
    and ((usuario_id is null and usuario_rol = 'sistema')
      or (usuario_id is not null and usuario_rol in ('operario','supervisor','admin'))))
  or (origen = 'sistema' and accion = 'sistema' and motivo <> 'automatico'
    and ((usuario_id is null and usuario_rol = 'sistema')
      or (usuario_id is not null and usuario_rol in ('operario','supervisor','admin'))))
);

-- Cada revisión de estado puede tener un solo evento, cualquiera sea su origen.
create unique index if not exists pedido_historial_revision_unica
  on public.pedido_estado_historial(pedido_id, revision_nueva);

create or replace function egeo_privado.auditar_estado_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_historial public.pedido_estado_historial%rowtype;
  v_actor public.perfiles%rowtype;
  v_automatico boolean := pg_trigger_depth() > 1;
  v_detalle text;
begin
  if new.estado is not distinct from old.estado then return new; end if;

  -- La RPC manual inserta su evento ANTES del UPDATE, en la misma transacción.
  -- Si ya existe, verificarlo y no fabricar un segundo evento automático.
  select * into v_historial from public.pedido_estado_historial
    where pedido_id = new.id and revision_nueva = new.estado_revision;
  if found then
    if v_historial.estado_anterior is distinct from old.estado
       or v_historial.estado_nuevo is distinct from new.estado
       or v_historial.revision_anterior is distinct from old.estado_revision then
      raise exception 'El evento de historial no coincide con el cambio de estado';
    end if;
    return new;
  end if;

  select * into v_actor from public.perfiles where id = auth.uid();
  v_detalle := case
    when v_automatico and old.estado = 'pendiente' and new.estado = 'en_curso'
      then 'El proceso registró actividad en la orden.'
    when v_automatico and new.estado = 'finalizado'
      then 'La producción registrada alcanzó la cantidad requerida en las etapas aplicables.'
    when v_automatico then 'El proceso recalculó el estado de la orden.'
    else 'Cambio directo en la base de datos, fuera de la acción manual de la aplicación.'
  end;
  insert into public.pedido_estado_historial (
    id, pedido_id, estado_anterior, estado_nuevo, accion,
    revision_anterior, revision_nueva, usuario_id, usuario_nombre,
    usuario_rol, motivo, origen, detalle_proceso
  ) values (
    gen_random_uuid(), new.id, old.estado, new.estado,
    case when v_automatico then 'automatico' else 'sistema' end,
    old.estado_revision, new.estado_revision, v_actor.id,
    coalesce(v_actor.nombre, 'Sistema'), coalesce(v_actor.rol, 'sistema'),
    case when v_automatico then 'automatico' else 'Cambio directo en la base de datos' end,
    case when v_automatico then 'automatico' else 'sistema' end,
    v_detalle
  );
  return new;
end $$;
revoke all on function egeo_privado.auditar_estado_pedido() from public, anon, authenticated;
drop trigger if exists trg_historial_estado_pedido on public.pedidos;
create trigger trg_historial_estado_pedido after update on public.pedidos
  for each row when (old.estado is distinct from new.estado)
  execute function egeo_privado.auditar_estado_pedido();

-- Redefinir la RPC manual para que su evento preceda al UPDATE auditado.
create or replace function public.cambiar_estado_pedido(
  p_solicitud uuid, p_pedido uuid, p_revision integer, p_accion text, p_motivo text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_usuario public.perfiles%rowtype;
  v_pedido public.pedidos%rowtype;
  v_historial public.pedido_estado_historial%rowtype;
  v_destino text;
begin
  perform public.validar_sesion();
  -- Mismo orden de bloqueos que gestionar_tarea: perfil y luego pedido.
  select * into v_usuario from public.perfiles where id = auth.uid() for share;
  if not v_usuario.activo or v_usuario.rol not in ('supervisor','admin') then
    raise exception 'Sólo supervisores y administradores pueden cambiar estados' using errcode = '42501';
  end if;
  if p_solicitud is null or p_pedido is null or p_revision is null or p_revision < 0
     or p_accion is null or p_accion not in ('en_curso','cancelado','finalizado','reabrir')
     or p_motivo is null or char_length(btrim(p_motivo)) not between 1 and 1000 then
    raise exception 'Indicá una acción y un motivo de 1 a 1000 caracteres' using errcode = '22023';
  end if;
  if translate(lower(btrim(p_motivo)), 'áéíóú', 'aeiou') = 'automatico' then
    raise exception 'El motivo automatico está reservado al proceso. Escribí el motivo real del cambio manual.' using errcode = '22023';
  end if;
  select * into v_pedido from public.pedidos where id = p_pedido for no key update;
  if not found then raise exception 'La orden no existe' using errcode = '22023'; end if;
  -- Un reintento conserva su UUID y no genera dos movimientos.
  select * into v_historial from public.pedido_estado_historial where id = p_solicitud;
  if found then
    if v_historial.pedido_id <> p_pedido or v_historial.usuario_id <> v_usuario.id
       or v_historial.accion <> p_accion or v_historial.motivo <> btrim(p_motivo)
       or v_historial.revision_anterior <> p_revision then
      raise exception 'La solicitud ya corresponde a otro cambio' using errcode = '22023';
    end if;
    return to_jsonb(v_historial);
  end if;
  if v_pedido.estado_revision <> p_revision then
    raise exception 'La orden cambió. Actualizá el estado antes de continuar.' using errcode = '40001';
  end if;
  if v_pedido.estado = 'pendiente' and p_accion in ('en_curso','cancelado') then
    v_destino := p_accion;
  elsif v_pedido.estado = 'en_curso' and p_accion = 'finalizado' then
    v_destino := case when coalesce((select avance from public.avance_pedido(p_pedido)), 0) >= v_pedido.cantidad
      then 'finalizado' else 'finalizado_pendientes' end;
  elsif v_pedido.estado in ('cancelado','finalizado_pendientes') and p_accion = 'reabrir' then
    v_destino := case when exists(select 1 from public.tareas where pedido_id = p_pedido)
      then 'en_curso' else 'pendiente' end;
  else
    raise exception 'Ese cambio de estado no está permitido' using errcode = '22023';
  end if;
  if v_destino in ('cancelado','finalizado','finalizado_pendientes') and exists (
    select 1 from public.tareas where pedido_id = p_pedido and not confirmada
  ) then
    raise exception 'Hay tareas abiertas, pausadas o pendientes de confirmar. Registralas primero.' using errcode = '22023';
  end if;

  insert into public.pedido_estado_historial(
    id, pedido_id, estado_anterior, estado_nuevo, accion, revision_anterior, revision_nueva,
    usuario_id, usuario_nombre, usuario_rol, motivo
  ) values (
    p_solicitud, p_pedido, v_pedido.estado, v_destino, p_accion, p_revision, p_revision + 1,
    v_usuario.id, v_usuario.nombre, v_usuario.rol, btrim(p_motivo)
  ) returning * into v_historial;
  update public.pedidos set estado = v_destino where id = p_pedido;
  return to_jsonb(v_historial);
end $$;

revoke all on function public.cambiar_estado_pedido(uuid,uuid,integer,text,text) from public, anon;
grant execute on function public.cambiar_estado_pedido(uuid,uuid,integer,text,text) to authenticated;
notify pgrst, 'reload schema';
commit;


-- Origen: migracion_11_indicadores.sql
-- Nueva consulta de solo lectura. Requiere migraciones 01 a 10.
begin;
create or replace function public.indicadores_egeo(
 p_desde date, p_hasta date, p_articulo text default '', p_proceso text default ''
) returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare resultado jsonb; n bigint;
begin
 if not coalesce(egeo_privado.sesion_activa(), false)
    or coalesce(public.rol_actual(), '') not in ('admin','supervisor') then
   raise exception 'Se requiere una sesión activa de supervisor o administrador' using errcode='42501';
 end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta)
    or p_hasta < p_desde or p_hasta - p_desde > 92 or p_hasta > current_date
    or length(coalesce(p_articulo,'')) > 100
    or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then
   raise exception 'Elegí un período de hasta 93 días, sin fechas futuras, y filtros válidos';
 end if;
 -- Fallar explícitamente antes que entregar detalles recortados.
 select count(*) into n from public.tareas
 where confirmada and fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz;
 if n > 20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with
 elegibles as (
   select p.id, p.codigo, p.articulo_id, a.nombre, a.codigo articulo_codigo,
     case when a.std_embolsado > 0 then 'embolsado'
          when a.std_armado > 0 then 'armado'
          when a.std_rebabado > 0 then 'rebabado'
          when a.std_inyectado > 0 then 'inyectado' end ultimo
   from public.pedidos p join public.articulos a on a.id=p.articulo_id
   where coalesce(p_articulo,'')='' or
     position(lower(p_articulo) in lower(a.codigo || ' ' || a.nombre))>0
 ),
 tareas as (
   select t.*, e.articulo_codigo, e.ultimo,
     case t.actividad when 'inyectado' then a.std_inyectado
       when 'rebabado' then a.std_rebabado when 'armado' then a.std_armado
       when 'embolsado' then a.std_embolsado end estandar
   from public.v_tareas t join elegibles e on e.id=t.pedido_id
   join public.articulos a on a.id=t.articulo_id
   where t.confirmada and t.fin is not null
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
 ),
 detalles as (
   select id,pedido_id,pedido_codigo,articulo_id,articulo_nombre,articulo_codigo,
     actividad,fin::date dia,piezas_ok,piezas_scrap,real_seg,std_seg,
     estandar, (actividad=ultimo) es_ultimo
   from tareas where fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz
 ),
 dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 -- Horas distribuidas por día real. Solo tareas confirmadas.
 horas as (
   select d.dia, coalesce(sum(greatest(0, extract(epoch from
     (least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))))
     - coalesce(x.pausa,0)) filter (where t.id is not null),0) real
   from dias d left join tareas t on t.inicio < (d.dia+1)::timestamptz and t.fin > d.dia::timestamptz
   left join lateral (
     select sum(greatest(0,extract(epoch from
       (least(coalesce(p.fin,t.fin),t.fin,(d.dia+1)::timestamptz)
        -greatest(p.inicio,t.inicio,d.dia::timestamptz))))) pausa
     from public.tarea_pausas p where p.tarea_id=t.id
   ) x on true group by d.dia
 ),
 pausas as (
   select d.dia, count(p.id) filter(where p.inicio >= d.dia::timestamptz
     and p.inicio < (d.dia+1)::timestamptz) cantidad,
     coalesce(sum(extract(epoch from
       (least(coalesce(p.fin,statement_timestamp()),(d.dia+1)::timestamptz)
        -greatest(p.inicio,d.dia::timestamptz)))) filter (where p.id is not null),0) segundos
   from dias d left join (
     public.tarea_pausas p join public.tareas t on t.id=p.tarea_id
     join elegibles e on e.id=t.pedido_id
   ) on p.inicio < least((d.dia+1)::timestamptz,statement_timestamp())
     and coalesce(p.fin,statement_timestamp()) > d.dia::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
   group by d.dia
 ),
 cierres as (
   select h.pedido_id, min(h.creado)::date dia
   from public.pedido_estado_historial h join elegibles e on e.id=h.pedido_id
   where h.estado_nuevo='finalizado'
   group by h.pedido_id
 ),
 diario as (
   select d.dia, coalesce(q.tareas,0) tareas,coalesce(q.piezas,0) piezas,
     coalesce(q.ok,0) ok,coalesce(q.scrap,0) scrap,
     greatest(0,h.real) real,pa.cantidad pausas,pa.segundos pausa_seg,
     (select count(*) from cierres c where c.dia=d.dia) ordenes,
     (select count(*) from public.mantenimientos m where m.fecha_ejecucion=d.dia) mantenimientos,
     (select coalesce(sum(m.minutos),0)*60 from public.mantenimientos m where m.fecha_ejecucion=d.dia) mantenimiento_seg,
     (select coalesce(sum(m.minutos),0)*60 from public.mantenimientos m where m.fecha_ejecucion=d.dia and not m.preventivo) correctivo_seg
   from dias d join horas h using(dia) join pausas pa using(dia)
   left join (
     select dia,count(*) tareas,sum(piezas_ok) ok,sum(piezas_scrap) scrap,
       sum(case when es_ultimo then piezas_ok else 0 end) piezas
     from detalles group by dia
   ) q using(dia)
 )
 select jsonb_build_object(
   'generado',statement_timestamp(),'desde',p_desde,'hasta',p_hasta,
   'tareas',coalesce((select jsonb_agg(to_jsonb(t) order by dia,id) from detalles t),'[]'::jsonb),
   'dias',coalesce((select jsonb_agg(to_jsonb(d) order by dia) from diario d),'[]'::jsonb),
   'sin_etapas',(select count(*) from detalles where es_ultimo is null),
   'finalizadas_sin_fecha',(select count(*) from public.pedidos p join elegibles e on e.id=p.id
     where p.estado='finalizado' and not exists(select 1 from cierres c where c.pedido_id=p.id))
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_egeo(date,date,text,text) from public,anon;
grant execute on function public.indicadores_egeo(date,date,text,text) to authenticated;
notify pgrst,'reload schema';
commit;


-- Origen: migracion_12_indicadores_admin_filtros.sql
-- Aplicar DESPUÉS de la migración 11. Solo administradores.
-- La función anterior pierde acceso desde el cliente; se evita eludir el nuevo permiso.
begin;
create or replace function public.indicadores_egeo_v2(
 p_desde date, p_hasta date, p_articulos uuid[] default null, p_proceso text default ''
) returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare resultado jsonb; n bigint;
begin
 if not coalesce(egeo_privado.sesion_activa(), false)
    or coalesce(public.rol_actual(), '') <> 'admin' then
   raise exception 'Se requiere una sesión activa de administrador' using errcode='42501';
 end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta)
    or p_hasta < p_desde or p_hasta - p_desde > 92 or p_hasta > current_date
    or coalesce(cardinality(p_articulos),0) > 50000
    or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then
   raise exception 'Elegí un período de hasta 93 días, sin fechas futuras, y filtros válidos';
 end if;
 -- Fallar explícitamente antes que entregar detalles recortados.
 select count(*) into n from public.tareas
 where confirmada and fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz;
 if n > 20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with
 elegibles as (
   select p.id, p.codigo, p.articulo_id, a.nombre, a.codigo articulo_codigo,
     case when a.std_embolsado > 0 then 'embolsado'
          when a.std_armado > 0 then 'armado'
          when a.std_rebabado > 0 then 'rebabado'
          when a.std_inyectado > 0 then 'inyectado' end ultimo
   from public.pedidos p join public.articulos a on a.id=p.articulo_id
   where p_articulos is null or a.id = any(p_articulos)
 ),
 tareas as (
   select t.*, e.articulo_codigo, e.ultimo,
     case t.actividad when 'inyectado' then a.std_inyectado
       when 'rebabado' then a.std_rebabado when 'armado' then a.std_armado
       when 'embolsado' then a.std_embolsado end estandar
   from public.v_tareas t join elegibles e on e.id=t.pedido_id
   join public.articulos a on a.id=t.articulo_id
   where t.confirmada and t.fin is not null
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
 ),
 detalles as (
   select id,pedido_id,pedido_codigo,articulo_id,articulo_nombre,articulo_codigo,
     actividad,fin::date dia,piezas_ok,piezas_scrap,real_seg,std_seg,
     estandar, (actividad=ultimo) es_ultimo
   from tareas where fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz
 ),
 dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 -- Horas distribuidas por día real. Solo tareas confirmadas.
 horas as (
   select d.dia, coalesce(sum(greatest(0, extract(epoch from
     (least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))))
     - coalesce(x.pausa,0)) filter (where t.id is not null),0) real
   from dias d left join tareas t on t.inicio < (d.dia+1)::timestamptz and t.fin > d.dia::timestamptz
   left join lateral (
     select sum(greatest(0,extract(epoch from
       (least(coalesce(p.fin,t.fin),t.fin,(d.dia+1)::timestamptz)
        -greatest(p.inicio,t.inicio,d.dia::timestamptz))))) pausa
     from public.tarea_pausas p where p.tarea_id=t.id
   ) x on true group by d.dia
 ),
 pausas as (
   select d.dia, count(p.id) filter(where p.inicio >= d.dia::timestamptz
     and p.inicio < (d.dia+1)::timestamptz) cantidad,
     coalesce(sum(extract(epoch from
       (least(coalesce(p.fin,statement_timestamp()),(d.dia+1)::timestamptz)
        -greatest(p.inicio,d.dia::timestamptz)))) filter (where p.id is not null),0) segundos
   from dias d left join (
     public.tarea_pausas p join public.tareas t on t.id=p.tarea_id
     join elegibles e on e.id=t.pedido_id
   ) on p.inicio < least((d.dia+1)::timestamptz,statement_timestamp())
     and coalesce(p.fin,statement_timestamp()) > d.dia::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
   group by d.dia
 ),
 cierres as (
   select h.pedido_id, min(h.creado)::date dia
   from public.pedido_estado_historial h join elegibles e on e.id=h.pedido_id
   where h.estado_nuevo='finalizado'
   group by h.pedido_id
 ),
 diario as (
   select d.dia, coalesce(q.tareas,0) tareas,coalesce(q.piezas,0) piezas,
     coalesce(q.ok,0) ok,coalesce(q.scrap,0) scrap,
     greatest(0,h.real) real,pa.cantidad pausas,pa.segundos pausa_seg,
     (select count(*) from cierres c where c.dia=d.dia) ordenes,
     (select count(*) from public.mantenimientos m where m.fecha_ejecucion=d.dia) mantenimientos,
     (select coalesce(sum(m.minutos),0)*60 from public.mantenimientos m where m.fecha_ejecucion=d.dia) mantenimiento_seg,
     (select coalesce(sum(m.minutos),0)*60 from public.mantenimientos m where m.fecha_ejecucion=d.dia and not m.preventivo) correctivo_seg
   from dias d join horas h using(dia) join pausas pa using(dia)
   left join (
     select dia,count(*) tareas,sum(piezas_ok) ok,sum(piezas_scrap) scrap,
       sum(case when es_ultimo then piezas_ok else 0 end) piezas
     from detalles group by dia
   ) q using(dia)
 )
 select jsonb_build_object(
   'catalogo',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'codigo',a.codigo,'nombre',a.nombre,'categoria',nullif(btrim(a.categoria),'')) order by a.nombre,a.id),'[]'::jsonb) from public.articulos a),
   'generado',statement_timestamp(),'desde',p_desde,'hasta',p_hasta,
   'tareas',coalesce((select jsonb_agg(to_jsonb(t) order by dia,id) from detalles t),'[]'::jsonb),
   'dias',coalesce((select jsonb_agg(to_jsonb(d) order by dia) from diario d),'[]'::jsonb),
   'sin_etapas',(select count(*) from detalles where es_ultimo is null),
   'finalizadas_sin_fecha',(select count(*) from public.pedidos p join elegibles e on e.id=p.id
     where p.estado='finalizado' and not exists(select 1 from cierres c where c.pedido_id=p.id))
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_egeo_v2(date,date,uuid[],text) from public,anon;
grant execute on function public.indicadores_egeo_v2(date,date,uuid[],text) to authenticated;
revoke all on function public.indicadores_egeo(date,date,text,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;


-- Origen: migracion_13_indicadores_rendimiento.sql
-- Aplicar DESPUÉS de la migración 12. Conserva firma, permisos y resultados.
-- Optimiza el período consultado y evita que tareas de artículos ajenos consuman el límite.
begin;
create index if not exists indicadores_tareas_fin_confirmadas
  on public.tareas (fin, pedido_id) where confirmada;
create index if not exists indicadores_mantenimientos_fecha
  on public.mantenimientos (fecha_ejecucion);
create index if not exists indicadores_historial_finalizado
  on public.pedido_estado_historial (pedido_id, creado) where estado_nuevo = 'finalizado';

create or replace function public.indicadores_egeo_v2(
 p_desde date, p_hasta date, p_articulos uuid[] default null, p_proceso text default ''
) returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare resultado jsonb; n bigint;
begin
 if not coalesce(egeo_privado.sesion_activa(), false)
    or coalesce(public.rol_actual(), '') <> 'admin' then
   raise exception 'Se requiere una sesión activa de administrador' using errcode='42501';
 end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta)
    or p_hasta < p_desde or p_hasta - p_desde > 92 or p_hasta > current_date
    or coalesce(cardinality(p_articulos),0) > 50000
    or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then
   raise exception 'Elegí un período de hasta 93 días, sin fechas futuras, y filtros válidos';
 end if;
 -- Fallar explícitamente antes que entregar detalles recortados.
 select count(*) into n from (
   select 1 from public.tareas t join public.pedidos p on p.id=t.pedido_id
   where t.confirmada and t.fin >= p_desde::timestamptz and t.fin < (p_hasta+1)::timestamptz
     and (p_articulos is null or p.articulo_id = any(p_articulos))
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
   limit 20001
 ) candidatas;
 if n > 20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with
 elegibles as (
   select p.id, p.codigo, p.articulo_id, a.nombre, a.codigo articulo_codigo,
     case when a.std_embolsado > 0 then 'embolsado'
          when a.std_armado > 0 then 'armado'
          when a.std_rebabado > 0 then 'rebabado'
          when a.std_inyectado > 0 then 'inyectado' end ultimo
   from public.pedidos p join public.articulos a on a.id=p.articulo_id
   where p_articulos is null or a.id = any(p_articulos)
 ),
 tareas as (
   select t.*, e.articulo_codigo, e.ultimo,
     case t.actividad when 'inyectado' then a.std_inyectado
       when 'rebabado' then a.std_rebabado when 'armado' then a.std_armado
       when 'embolsado' then a.std_embolsado end estandar
   from public.v_tareas t join elegibles e on e.id=t.pedido_id
   join public.articulos a on a.id=t.articulo_id
   where t.confirmada and t.fin >= p_desde::timestamptz
     and t.inicio < (p_hasta+1)::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
 ),
 detalles as (
   select id,pedido_id,pedido_codigo,articulo_id,articulo_nombre,articulo_codigo,
     actividad,fin::date dia,piezas_ok,piezas_scrap,real_seg,std_seg,
     estandar, (actividad=ultimo) es_ultimo
   from tareas where fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz
 ),
 dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 -- Horas distribuidas por día real. Solo tareas confirmadas.
 horas as (
   select d.dia, coalesce(sum(greatest(0, extract(epoch from
     (least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))))
     - coalesce(x.pausa,0)) filter (where t.id is not null),0) real
   from dias d left join tareas t on t.inicio < (d.dia+1)::timestamptz and t.fin > d.dia::timestamptz
   left join lateral (
     select sum(greatest(0,extract(epoch from
       (least(coalesce(p.fin,t.fin),t.fin,(d.dia+1)::timestamptz)
        -greatest(p.inicio,t.inicio,d.dia::timestamptz))))) pausa
     from public.tarea_pausas p where p.tarea_id=t.id
   ) x on true group by d.dia
 ),
 pausas as (
   select d.dia, count(p.id) filter(where p.inicio >= d.dia::timestamptz
     and p.inicio < (d.dia+1)::timestamptz) cantidad,
     coalesce(sum(extract(epoch from
       (least(coalesce(p.fin,statement_timestamp()),(d.dia+1)::timestamptz)
        -greatest(p.inicio,d.dia::timestamptz)))) filter (where p.id is not null),0) segundos
   from dias d left join (
     public.tarea_pausas p join public.tareas t on t.id=p.tarea_id
     join elegibles e on e.id=t.pedido_id
   ) on p.inicio < least((d.dia+1)::timestamptz,statement_timestamp())
     and coalesce(p.fin,statement_timestamp()) > d.dia::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
   group by d.dia
 ),
 cierres as (
   select h.pedido_id, min(h.creado)::date dia
   from public.pedido_estado_historial h join elegibles e on e.id=h.pedido_id
   where h.estado_nuevo='finalizado'
   group by h.pedido_id
 ),
 mantenimiento_diario as (
   select fecha_ejecucion dia, count(*) cantidad, sum(minutos)::numeric*60 segundos,
     coalesce(sum(minutos) filter (where not preventivo),0)::numeric*60 correctivo
   from public.mantenimientos where fecha_ejecucion between p_desde and p_hasta
   group by fecha_ejecucion
 ),
 diario as (
   select d.dia, coalesce(q.tareas,0) tareas,coalesce(q.piezas,0) piezas,
     coalesce(q.ok,0) ok,coalesce(q.scrap,0) scrap,
     greatest(0,h.real) real,pa.cantidad pausas,pa.segundos pausa_seg,
     (select count(*) from cierres c where c.dia=d.dia) ordenes,
     coalesce(m.cantidad,0) mantenimientos,
     coalesce(m.segundos,0) mantenimiento_seg,
     coalesce(m.correctivo,0) correctivo_seg
   from dias d join horas h using(dia) join pausas pa using(dia)
   left join mantenimiento_diario m using(dia)
   left join (
     select dia,count(*) tareas,sum(piezas_ok) ok,sum(piezas_scrap) scrap,
       sum(case when es_ultimo then piezas_ok else 0 end) piezas
     from detalles group by dia
   ) q using(dia)
 )
 select jsonb_build_object(
   'catalogo',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'codigo',a.codigo,'nombre',a.nombre,'categoria',nullif(btrim(a.categoria),'')) order by a.nombre,a.id),'[]'::jsonb) from public.articulos a),
   'generado',statement_timestamp(),'desde',p_desde,'hasta',p_hasta,
   'tareas',coalesce((select jsonb_agg(to_jsonb(t) order by dia,id) from detalles t),'[]'::jsonb),
   'dias',coalesce((select jsonb_agg(to_jsonb(d) order by dia) from diario d),'[]'::jsonb),
   'sin_etapas',(select count(*) from detalles where es_ultimo is null),
   'finalizadas_sin_fecha',(select count(*) from public.pedidos p join elegibles e on e.id=p.id
     where p.estado='finalizado' and not exists(select 1 from cierres c where c.pedido_id=p.id))
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_egeo_v2(date,date,uuid[],text) from public,anon;
grant execute on function public.indicadores_egeo_v2(date,date,uuid[],text) to authenticated;
revoke all on function public.indicadores_egeo(date,date,text,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;


-- Origen: migracion_14_indicadores_usuario.sql
-- Aplicar DESPUÉS de la migración 13. Agrega el filtro por usuario (operario) a indicadores.
-- Cambia la firma: se elimina la versión de 4 parámetros y se crea la de 5.
begin;
drop function if exists public.indicadores_egeo_v2(date,date,uuid[],text);
create index if not exists indicadores_tareas_operario
  on public.tareas (operario_id, fin) where confirmada;
create index if not exists indicadores_tareas_fin_confirmadas
  on public.tareas (fin, pedido_id) where confirmada;
create index if not exists indicadores_mantenimientos_fecha
  on public.mantenimientos (fecha_ejecucion);
create index if not exists indicadores_historial_finalizado
  on public.pedido_estado_historial (pedido_id, creado) where estado_nuevo = 'finalizado';

create or replace function public.indicadores_egeo_v2(
 p_desde date, p_hasta date, p_articulos uuid[] default null, p_proceso text default '',
 p_operario uuid default null
) returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare resultado jsonb; n bigint;
begin
 if not coalesce(egeo_privado.sesion_activa(), false)
    or coalesce(public.rol_actual(), '') <> 'admin' then
   raise exception 'Se requiere una sesión activa de administrador' using errcode='42501';
 end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta)
    or p_hasta < p_desde or p_hasta - p_desde > 92 or p_hasta > current_date
    or coalesce(cardinality(p_articulos),0) > 50000
    or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then
   raise exception 'Elegí un período de hasta 93 días, sin fechas futuras, y filtros válidos';
 end if;
 -- Fallar explícitamente antes que entregar detalles recortados.
 select count(*) into n from (
   select 1 from public.tareas t join public.pedidos p on p.id=t.pedido_id
   where t.confirmada and t.fin >= p_desde::timestamptz and t.fin < (p_hasta+1)::timestamptz
     and (p_articulos is null or p.articulo_id = any(p_articulos))
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
   limit 20001
 ) candidatas;
 if n > 20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with
 elegibles as (
   select p.id, p.codigo, p.articulo_id, a.nombre, a.codigo articulo_codigo,
     case when a.std_embolsado > 0 then 'embolsado'
          when a.std_armado > 0 then 'armado'
          when a.std_rebabado > 0 then 'rebabado'
          when a.std_inyectado > 0 then 'inyectado' end ultimo
   from public.pedidos p join public.articulos a on a.id=p.articulo_id
   where p_articulos is null or a.id = any(p_articulos)
 ),
 tareas as (
   select t.*, e.articulo_codigo, e.ultimo,
     case t.actividad when 'inyectado' then a.std_inyectado
       when 'rebabado' then a.std_rebabado when 'armado' then a.std_armado
       when 'embolsado' then a.std_embolsado end estandar
   from public.v_tareas t join elegibles e on e.id=t.pedido_id
   join public.articulos a on a.id=t.articulo_id
   where t.confirmada and t.fin >= p_desde::timestamptz
     and t.inicio < (p_hasta+1)::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
 ),
 detalles as (
   select id,pedido_id,pedido_codigo,articulo_id,articulo_nombre,articulo_codigo,
     actividad,operario_id,operario_nombre,fin::date dia,piezas_ok,piezas_scrap,real_seg,std_seg,
     estandar, (actividad=ultimo) es_ultimo
   from tareas where fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz
 ),
 dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 -- Horas distribuidas por día real. Solo tareas confirmadas.
 horas as (
   select d.dia, coalesce(sum(greatest(0, extract(epoch from
     (least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))))
     - coalesce(x.pausa,0)) filter (where t.id is not null),0) real
   from dias d left join tareas t on t.inicio < (d.dia+1)::timestamptz and t.fin > d.dia::timestamptz
   left join lateral (
     select sum(greatest(0,extract(epoch from
       (least(coalesce(p.fin,t.fin),t.fin,(d.dia+1)::timestamptz)
        -greatest(p.inicio,t.inicio,d.dia::timestamptz))))) pausa
     from public.tarea_pausas p where p.tarea_id=t.id
   ) x on true group by d.dia
 ),
 pausas as (
   select d.dia, count(p.id) filter(where p.inicio >= d.dia::timestamptz
     and p.inicio < (d.dia+1)::timestamptz) cantidad,
     coalesce(sum(extract(epoch from
       (least(coalesce(p.fin,statement_timestamp()),(d.dia+1)::timestamptz)
        -greatest(p.inicio,d.dia::timestamptz)))) filter (where p.id is not null),0) segundos
   from dias d left join (
     public.tarea_pausas p join public.tareas t on t.id=p.tarea_id
     join elegibles e on e.id=t.pedido_id
   ) on p.inicio < least((d.dia+1)::timestamptz,statement_timestamp())
     and coalesce(p.fin,statement_timestamp()) > d.dia::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
   group by d.dia
 ),
 cierres as (
   select h.pedido_id, min(h.creado)::date dia
   from public.pedido_estado_historial h join elegibles e on e.id=h.pedido_id
   where h.estado_nuevo='finalizado'
   group by h.pedido_id
 ),
 mantenimiento_diario as (
   select fecha_ejecucion dia, count(*) cantidad, sum(minutos)::numeric*60 segundos,
     coalesce(sum(minutos) filter (where not preventivo),0)::numeric*60 correctivo
   from public.mantenimientos where fecha_ejecucion between p_desde and p_hasta
   group by fecha_ejecucion
 ),
 diario as (
   select d.dia, coalesce(q.tareas,0) tareas,coalesce(q.piezas,0) piezas,
     coalesce(q.ok,0) ok,coalesce(q.scrap,0) scrap,
     greatest(0,h.real) real,pa.cantidad pausas,pa.segundos pausa_seg,
     (select count(*) from cierres c where c.dia=d.dia) ordenes,
     coalesce(m.cantidad,0) mantenimientos,
     coalesce(m.segundos,0) mantenimiento_seg,
     coalesce(m.correctivo,0) correctivo_seg
   from dias d join horas h using(dia) join pausas pa using(dia)
   left join mantenimiento_diario m using(dia)
   left join (
     select dia,count(*) tareas,sum(piezas_ok) ok,sum(piezas_scrap) scrap,
       sum(case when es_ultimo then piezas_ok else 0 end) piezas
     from detalles group by dia
   ) q using(dia)
 )
 select jsonb_build_object(
   'catalogo',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'codigo',a.codigo,'nombre',a.nombre,'categoria',nullif(btrim(a.categoria),'')) order by a.nombre,a.id),'[]'::jsonb) from public.articulos a),
   'usuarios',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'nombre',u.nombre) order by u.nombre,u.id),'[]'::jsonb)
     from public.perfiles u where exists(select 1 from public.tareas t where t.operario_id=u.id)),
   'operario',p_operario,
   'generado',statement_timestamp(),'desde',p_desde,'hasta',p_hasta,
   'tareas',coalesce((select jsonb_agg(to_jsonb(t) order by dia,id) from detalles t),'[]'::jsonb),
   'dias',coalesce((select jsonb_agg(to_jsonb(d) order by dia) from diario d),'[]'::jsonb),
   'sin_etapas',(select count(*) from detalles where es_ultimo is null),
   'finalizadas_sin_fecha',(select count(*) from public.pedidos p join elegibles e on e.id=p.id
     where p.estado='finalizado' and not exists(select 1 from cierres c where c.pedido_id=p.id))
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_egeo_v2(date,date,uuid[],text,uuid) from public,anon;
grant execute on function public.indicadores_egeo_v2(date,date,uuid[],text,uuid) to authenticated;
revoke all on function public.indicadores_egeo(date,date,text,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;

-- Origen: migracion_15_editar_cantidad.sql
-- Aplicar DESPUÉS de la migración 14.
-- Permite a supervisores y administradores cambiar la cantidad a fabricar de
-- cualquier orden, en cualquier estado. Reglas:
--   * la cantidad debe ser mayor que cero;
--   * no puede ser menor a lo ya fabricado (piezas OK confirmadas) en ninguno
--     de los procesos que aplican al artículo (estándar > 0).
-- Cada cambio queda auditado y el estado se recalcula con la nueva cantidad.
begin;

create table if not exists public.pedido_cantidad_historial (
  id uuid primary key default gen_random_uuid(),
  pedido_id uuid not null references public.pedidos(id) on delete restrict,
  cantidad_anterior integer not null,
  cantidad_nueva integer not null check (cantidad_nueva > 0),
  usuario_id uuid not null references auth.users(id) on delete restrict,
  usuario_nombre text not null,
  creado timestamptz not null default clock_timestamp()
);
create index if not exists pedido_cantidad_historial_orden
  on public.pedido_cantidad_historial(pedido_id, creado desc);
alter table public.pedido_cantidad_historial enable row level security;
revoke all on public.pedido_cantidad_historial from public, anon, authenticated;
grant select on public.pedido_cantidad_historial to authenticated;
drop policy if exists cantidad_historial_lectura on public.pedido_cantidad_historial;
create policy cantidad_historial_lectura on public.pedido_cantidad_historial
  for select to authenticated using (public.rol_actual() in ('admin','supervisor'));

create or replace function public.editar_cantidad_pedido(p_pedido uuid, p_cantidad integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_usuario public.perfiles%rowtype;
  v_pedido  public.pedidos%rowtype;
  v_art     public.articulos%rowtype;
  v_minimo  integer;
  v_avance  integer;
  v_destino text;
begin
  perform public.validar_sesion();
  -- Mismo orden de bloqueos que gestionar_tarea y cambiar_estado_pedido: perfil y luego pedido.
  select * into v_usuario from public.perfiles where id = auth.uid() for share;
  if not found or not v_usuario.activo or v_usuario.rol not in ('supervisor','admin') then
    raise exception 'Sólo supervisores y administradores pueden editar cantidades' using errcode = '42501';
  end if;
  if p_pedido is null or p_cantidad is null or p_cantidad <= 0 then
    raise exception 'La cantidad debe ser mayor que cero' using errcode = '22023';
  end if;

  select * into v_pedido from public.pedidos where id = p_pedido for no key update;
  if not found then raise exception 'La orden no existe' using errcode = '22023'; end if;
  select * into v_art from public.articulos where id = v_pedido.articulo_id;

  -- Mayor cantidad OK confirmada entre los procesos que aplican al artículo.
  select coalesce(max(x.ok), 0) into v_minimo from (
    select sum(t.piezas_ok)::integer ok
    from public.tareas t
    where t.pedido_id = p_pedido and t.confirmada
      and coalesce(case t.actividad
            when 'inyectado' then v_art.std_inyectado
            when 'rebabado'  then v_art.std_rebabado
            when 'armado'    then v_art.std_armado
            when 'embolsado' then v_art.std_embolsado end, 0) > 0
    group by t.actividad
  ) x;
  -- Artículo sin estándares: se toma el total, igual que avance_pedido.
  if coalesce(v_art.std_inyectado,0) <= 0 and coalesce(v_art.std_rebabado,0) <= 0
     and coalesce(v_art.std_armado,0) <= 0 and coalesce(v_art.std_embolsado,0) <= 0 then
    select coalesce(sum(piezas_ok), 0)::integer into v_minimo
      from public.tareas where pedido_id = p_pedido and confirmada;
  end if;

  if p_cantidad < v_minimo then
    raise exception 'La cantidad no puede ser menor a % (ya fabricadas en un proceso del artículo)', v_minimo
      using errcode = '22023';
  end if;
  if p_cantidad = v_pedido.cantidad then
    return jsonb_build_object('id', p_pedido, 'cantidad', p_cantidad, 'estado', v_pedido.estado, 'minimo', v_minimo);
  end if;

  update public.pedidos set cantidad = p_cantidad where id = p_pedido;
  insert into public.pedido_cantidad_historial (pedido_id, cantidad_anterior, cantidad_nueva, usuario_id, usuario_nombre)
    values (p_pedido, v_pedido.cantidad, p_cantidad, v_usuario.id, v_usuario.nombre);

  -- Recalcular el estado con la nueva cantidad.
  select avance into v_avance from egeo_privado.avance_pedido_interno(p_pedido);
  v_avance := coalesce(v_avance, 0);
  v_destino := case
    -- Abierta que ya alcanzó la nueva cantidad: se cierra sola si no hay tareas sin confirmar
    -- (si las hay, el cierre llega al confirmarlas, por el disparador existente).
    when v_pedido.estado in ('pendiente','en_curso') and v_avance >= p_cantidad
         and not exists (select 1 from public.tareas where pedido_id = p_pedido and not confirmada)
      then 'finalizado'
    -- Finalizada a la que ahora le falta producción.
    when v_pedido.estado = 'finalizado' and v_avance < p_cantidad then 'finalizado_pendientes'
    -- Finalizada con pendientes que ya quedó completa.
    when v_pedido.estado = 'finalizado_pendientes' and v_avance >= p_cantidad then 'finalizado'
    else v_pedido.estado
  end;

  if v_destino <> v_pedido.estado then
    -- El evento se inserta ANTES del UPDATE, como en cambiar_estado_pedido:
    -- el disparador de auditoría lo encuentra y no crea un segundo registro.
    insert into public.pedido_estado_historial (
      id, pedido_id, estado_anterior, estado_nuevo, accion,
      revision_anterior, revision_nueva, usuario_id, usuario_nombre,
      usuario_rol, motivo, origen, detalle_proceso
    ) values (
      gen_random_uuid(), p_pedido, v_pedido.estado, v_destino, 'sistema',
      v_pedido.estado_revision, v_pedido.estado_revision + 1, v_usuario.id, v_usuario.nombre,
      v_usuario.rol, format('Cantidad a fabricar modificada de %s a %s', v_pedido.cantidad, p_cantidad),
      'sistema', 'El estado se recalculó por el cambio de cantidad a fabricar.'
    );
    update public.pedidos set estado = v_destino where id = p_pedido;
  end if;

  return jsonb_build_object('id', p_pedido, 'cantidad', p_cantidad, 'estado', v_destino, 'minimo', v_minimo);
end $$;

revoke all on function public.editar_cantidad_pedido(uuid, integer) from public, anon;
grant execute on function public.editar_cantidad_pedido(uuid, integer) to authenticated;
notify pgrst, 'reload schema';
commit;

-- Origen: migracion_16_exportables.sql
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

-- Origen: migracion_17_permisos_roles.sql
-- Aplicar DESPUÉS de la migración 16.
-- Permisos por rol (matriz propuesta):
--   * Operario: puede crear y consultar órdenes, y registrar y consultar mantenimientos.
--   * Supervisor: deja de cambiar estados y reabrir órdenes (solo administrador).
--     Sigue viendo el historial de estados.
--   * El tablero sin acceso para supervisor se resuelve en el frontend (no hay datos exclusivos).
-- Las funciones se redefinen completas; solo cambia la lista de roles permitidos.
begin;

-- Operario puede crear órdenes.
drop policy if exists pedidos_insert on public.pedidos;
create policy pedidos_insert on public.pedidos for insert to authenticated
  with check (public.rango(public.rol_actual()) >= 1);

-- Operario puede consultar mantenimientos.
drop policy if exists mantenimientos_lectura on public.mantenimientos;
create policy mantenimientos_lectura on public.mantenimientos for select to authenticated
  using (public.rol_actual() in ('admin', 'supervisor', 'operario'));

-- ejecutores_mantenimiento: se agrega operario.
CREATE OR REPLACE FUNCTION public.ejecutores_mantenimiento()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform public.validar_sesion();
  if auth.uid() is null or public.rol_actual() not in ('admin', 'supervisor', 'operario')
     or public.rol_actual() is null then
    raise exception 'Se requiere un usuario activo' using errcode = '42501';
  end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre)
    order by nombre, id), '[]'::jsonb) from public.perfiles where activo);
end;
$function$;

-- registrar_mantenimiento: se agrega operario.
CREATE OR REPLACE FUNCTION public.registrar_mantenimiento(p_id uuid, p_ejecutor_id uuid, p_fecha_ejecucion date, p_detalle text, p_preventivo boolean, p_minutos integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_registrante public.perfiles%rowtype;
  v_ejecutor public.perfiles%rowtype;
  v_registro public.mantenimientos%rowtype;
begin
  perform public.validar_sesion();
  select * into v_registrante from public.perfiles where id = auth.uid() for share;
  if not found or not v_registrante.activo or v_registrante.rol not in ('admin', 'supervisor', 'operario') then
    raise exception 'Se requiere un usuario activo' using errcode = '42501';
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
$function$;

-- exportar_mantenimientos: se agrega operario.
CREATE OR REPLACE FUNCTION public.exportar_mantenimientos()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET "TimeZone" TO 'UTC'
AS $function$
declare v_columnas jsonb;
begin
  perform public.validar_sesion();
  if auth.uid() is null or public.rol_actual() not in ('admin', 'supervisor', 'operario')
     or public.rol_actual() is null then
    raise exception 'Se requiere un usuario activo' using errcode = '42501';
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
$function$;

-- cambiar_estado_pedido: solo administrador.
CREATE OR REPLACE FUNCTION public.cambiar_estado_pedido(p_solicitud uuid, p_pedido uuid, p_revision integer, p_accion text, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_usuario public.perfiles%rowtype;
  v_pedido public.pedidos%rowtype;
  v_historial public.pedido_estado_historial%rowtype;
  v_destino text;
begin
  perform public.validar_sesion();
  -- Mismo orden de bloqueos que gestionar_tarea: perfil y luego pedido.
  select * into v_usuario from public.perfiles where id = auth.uid() for share;
  if not v_usuario.activo or v_usuario.rol <> 'admin' then
    raise exception 'Sólo administradores pueden cambiar estados' using errcode = '42501';
  end if;
  if p_solicitud is null or p_pedido is null or p_revision is null or p_revision < 0
     or p_accion is null or p_accion not in ('en_curso','cancelado','finalizado','reabrir')
     or p_motivo is null or char_length(btrim(p_motivo)) not between 1 and 1000 then
    raise exception 'Indicá una acción y un motivo de 1 a 1000 caracteres' using errcode = '22023';
  end if;
  if translate(lower(btrim(p_motivo)), 'áéíóú', 'aeiou') = 'automatico' then
    raise exception 'El motivo automatico está reservado al proceso. Escribí el motivo real del cambio manual.' using errcode = '22023';
  end if;
  select * into v_pedido from public.pedidos where id = p_pedido for no key update;
  if not found then raise exception 'La orden no existe' using errcode = '22023'; end if;
  -- Un reintento conserva su UUID y no genera dos movimientos.
  select * into v_historial from public.pedido_estado_historial where id = p_solicitud;
  if found then
    if v_historial.pedido_id <> p_pedido or v_historial.usuario_id <> v_usuario.id
       or v_historial.accion <> p_accion or v_historial.motivo <> btrim(p_motivo)
       or v_historial.revision_anterior <> p_revision then
      raise exception 'La solicitud ya corresponde a otro cambio' using errcode = '22023';
    end if;
    return to_jsonb(v_historial);
  end if;
  if v_pedido.estado_revision <> p_revision then
    raise exception 'La orden cambió. Actualizá el estado antes de continuar.' using errcode = '40001';
  end if;
  if v_pedido.estado = 'pendiente' and p_accion in ('en_curso','cancelado') then
    v_destino := p_accion;
  elsif v_pedido.estado = 'en_curso' and p_accion = 'finalizado' then
    v_destino := case when coalesce((select avance from public.avance_pedido(p_pedido)), 0) >= v_pedido.cantidad
      then 'finalizado' else 'finalizado_pendientes' end;
  elsif v_pedido.estado in ('cancelado','finalizado_pendientes') and p_accion = 'reabrir' then
    v_destino := case when exists(select 1 from public.tareas where pedido_id = p_pedido)
      then 'en_curso' else 'pendiente' end;
  else
    raise exception 'Ese cambio de estado no está permitido' using errcode = '22023';
  end if;
  if v_destino in ('cancelado','finalizado','finalizado_pendientes') and exists (
    select 1 from public.tareas where pedido_id = p_pedido and not confirmada
  ) then
    raise exception 'Hay tareas abiertas, pausadas o pendientes de confirmar. Registralas primero.' using errcode = '22023';
  end if;

  insert into public.pedido_estado_historial(
    id, pedido_id, estado_anterior, estado_nuevo, accion, revision_anterior, revision_nueva,
    usuario_id, usuario_nombre, usuario_rol, motivo
  ) values (
    p_solicitud, p_pedido, v_pedido.estado, v_destino, p_accion, p_revision, p_revision + 1,
    v_usuario.id, v_usuario.nombre, v_usuario.rol, btrim(p_motivo)
  ) returning * into v_historial;
  update public.pedidos set estado = v_destino where id = p_pedido;
  return to_jsonb(v_historial);
end $function$;

notify pgrst, 'reload schema';
commit;

-- Origen: migracion_18_admin tareas pausas.sql
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

-- Origen: migracion_19_tareas por usuario.sql
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