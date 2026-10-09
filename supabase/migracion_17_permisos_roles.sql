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