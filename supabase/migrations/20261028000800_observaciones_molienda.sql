-- Preserva las observaciones de molienda al resolver y exportar intervenciones.
begin;
create or replace function public.gestionar_solicitud(p_accion text,p_id uuid,p_datos jsonb default '{}',p_revision integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.solicitudes_trabajo%rowtype; anterior jsonb; gestor boolean; uid uuid:=auth.uid(); v_nombre text;
begin
 perform public.validar_sesion();
 gestor:=public.rango(public.rol_actual())>=2;
 perform 1 from public.perfiles where id=uid for update;
 if p_id is null then raise exception 'Identificador obligatorio'; end if;
 if p_accion='crear' then
  if not gestor then raise exception 'Solo supervisor o administrador puede solicitar' using errcode='42501'; end if;
  if p_datos->>'asignado_id' is not null then
   perform 1 from public.perfiles where id=(p_datos->>'asignado_id')::uuid and activo for share;
   if not found then raise exception 'Elegí un usuario activo'; end if;
  end if;
  if p_datos->>'tipo'='mantenimiento' then
   if p_datos->>'maquina_id' is not null and not exists(select 1 from public.maquinas where id=(p_datos->>'maquina_id')::uuid and activo) then raise exception 'Máquina inactiva'; end if;
   if p_datos->>'equipo_id' is not null and not exists(select 1 from public.equipos where id=(p_datos->>'equipo_id')::uuid and activo) then raise exception 'Equipo inactivo'; end if;
  end if;
  insert into public.solicitudes_trabajo(id,tipo,maquina_id,equipo_id,detalle,preventivo,solicitado_por,asignado_id,estado)
  values(p_id,p_datos->>'tipo',(p_datos->>'maquina_id')::uuid,(p_datos->>'equipo_id')::uuid,
   btrim(coalesce(p_datos->>'detalle','')),coalesce((p_datos->>'preventivo')::boolean,false),uid,(p_datos->>'asignado_id')::uuid,
   case when p_datos->>'asignado_id' is null then 'pendiente' else 'asignada' end)
  on conflict(id) do nothing returning * into s;
  if s.id is null then
   select * into s from public.solicitudes_trabajo where id=p_id;
   if s.solicitado_por=uid and s.tipo=p_datos->>'tipo' and s.detalle=btrim(coalesce(p_datos->>'detalle',''))
    and s.maquina_id is not distinct from (p_datos->>'maquina_id')::uuid and s.equipo_id is not distinct from (p_datos->>'equipo_id')::uuid
    and s.asignado_id is not distinct from (p_datos->>'asignado_id')::uuid then return to_jsonb(s); end if;
   raise exception 'Identificador usado por otra solicitud';
  end if;
 else
  select * into s from public.solicitudes_trabajo where id=p_id for update;
  if not found or (not gestor and s.asignado_id is distinct from uid) then raise exception 'Solicitud no disponible' using errcode='42501'; end if;
  if s.revision is distinct from p_revision then raise exception 'La tarea cambió. Actualizá antes de continuar'; end if;
  if s.estado='resuelta' then raise exception 'La tarea ya está resuelta'; end if;
  anterior:=to_jsonb(s);
  if p_accion='asignar' then
   if not gestor then raise exception 'Solo supervisor o administrador puede asignar' using errcode='42501'; end if;
   perform 1 from public.perfiles where id=(p_datos->>'asignado_id')::uuid and activo for share;
   if not found then raise exception 'Elegí un usuario activo'; end if;
   update public.solicitudes_trabajo set asignado_id=(p_datos->>'asignado_id')::uuid,
    estado=case when estado='en_curso' then estado else 'asignada' end,revision=revision+1 where id=p_id returning * into s;
  elsif p_accion='iniciar' then
   if s.estado<>'asignada' then raise exception 'La tarea debe estar asignada'; end if;
   update public.solicitudes_trabajo set inicio=clock_timestamp(),estado='en_curso',revision=revision+1 where id=p_id returning * into s;
  elsif p_accion='resolver' then
   if s.estado not in ('asignada','en_curso') then raise exception 'Primero asigná la tarea'; end if;
   if (p_datos->>'minutos')::integer is null or (p_datos->>'minutos')::integer<=0 then raise exception 'Cargá minutos positivos'; end if;
   if s.tipo='mantenimiento' and btrim(coalesce(p_datos->>'resolucion',''))='' then raise exception 'Describí lo realizado'; end if;
   if char_length(coalesce(p_datos->>'resolucion',''))>5000 then raise exception 'Las observaciones admiten hasta 5000 caracteres'; end if;
   select nombre into v_nombre from public.perfiles where id=uid;
   insert into public.mantenimientos(id,registrado_por,registrado_nombre,ejecutor_id,ejecutor_nombre,fecha_ejecucion,detalle,preventivo,minutos)
   select s.id,uid,v_nombre,s.asignado_id,p.nombre,(clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date,
    case when s.tipo='molienda' then coalesce(nullif(btrim(p_datos->>'resolucion'),''),'Molienda') else btrim(p_datos->>'resolucion') end,s.preventivo,(p_datos->>'minutos')::integer
   from public.perfiles p where p.id=s.asignado_id;
   update public.solicitudes_trabajo set estado='resuelta',resuelto=clock_timestamp(),resolucion=btrim(coalesce(p_datos->>'resolucion','')),
    minutos=(p_datos->>'minutos')::integer,mantenimiento_id=s.id,revision=revision+1 where id=p_id returning * into s;
  else raise exception 'Acción inválida'; end if;
 end if;
 insert into public.solicitud_historial(solicitud_id,usuario_id,antes,despues) values(s.id,uid,anterior,to_jsonb(s));
 return to_jsonb(s);
end $$;
notify pgrst,'reload schema';
commit;
