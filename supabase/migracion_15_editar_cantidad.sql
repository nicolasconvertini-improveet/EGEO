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