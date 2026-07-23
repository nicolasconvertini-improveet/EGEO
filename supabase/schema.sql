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

