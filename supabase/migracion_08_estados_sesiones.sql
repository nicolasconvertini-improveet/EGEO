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
