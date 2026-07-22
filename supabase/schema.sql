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
  fin          timestamptz not null,
  piezas_ok    int not null default 0,
  piezas_scrap int not null default 0,
  creado       timestamptz not null default now()
);

create index if not exists idx_tareas_pedido on public.tareas(pedido_id);
create index if not exists idx_pedidos_estado on public.pedidos(estado);

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

-- actualizar estado del pedido según el avance (se dispara al registrar tareas)
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_total  int;
  v_meta   int;
begin
  select coalesce(sum(piezas_ok),0) into v_total from public.tareas where pedido_id = v_pedido;
  select cantidad into v_meta from public.pedidos where id = v_pedido;
  update public.pedidos
     set estado = case
       when v_total >= v_meta then 'finalizado'
       when v_total > 0       then 'en_curso'
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
create or replace view public.v_pedidos with (security_invoker = on) as
  select p.id, p.codigo, p.articulo_id,
         a.nombre as articulo_nombre, a.codigo as articulo_codigo,
         p.cantidad, p.estado, p.creado,
         coalesce(sum(t.piezas_ok),0)::int   as ok_acum,
         coalesce(sum(t.piezas_scrap),0)::int as scrap_acum
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
    left join public.tareas t on t.pedido_id = p.id
   group by p.id, a.nombre, a.codigo;

create or replace view public.v_tareas with (security_invoker = on) as
  select t.id, t.pedido_id, p.codigo as pedido_codigo, p.articulo_id,
         a.nombre as articulo_nombre, t.actividad,
         coalesce(pe.nombre,'—') as operario_nombre, t.operario_id,
         t.inicio, t.fin, t.piezas_ok, t.piezas_scrap, t.creado,
         greatest(1, extract(epoch from (t.fin - t.inicio)))::int as real_seg,
         (t.piezas_ok * (case t.actividad
            when 'inyectado' then a.std_inyectado
            when 'rebabado'  then a.std_rebabado
            when 'armado'    then a.std_armado
            when 'embolsado' then a.std_embolsado end))::numeric as std_seg
    from public.tareas t
    join public.pedidos p on p.id = t.pedido_id
    join public.articulos a on a.id = p.articulo_id
    left join public.perfiles pe on pe.id = t.operario_id;

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
