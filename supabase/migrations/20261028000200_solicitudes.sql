begin;
create table public.solicitudes_trabajo (
 id uuid primary key default gen_random_uuid(), tipo text not null check(tipo in ('mantenimiento','molienda')),
 estado text not null default 'pendiente' check(estado in ('pendiente','asignada','en_curso','resuelta')),
 maquina_id uuid references public.maquinas(id), equipo_id uuid references public.equipos(id),
 detalle text not null default '' check(length(detalle)<=5000), preventivo boolean not null default false,
 solicitado_por uuid not null references public.perfiles(id), asignado_id uuid references public.perfiles(id),
 creado timestamptz not null default now(), inicio timestamptz, resuelto timestamptz, resolucion text not null default '',
 minutos integer check(minutos>0), revision integer not null default 0,
 mantenimiento_id uuid unique references public.mantenimientos(id),
 check(tipo='molienda' or (num_nonnulls(maquina_id,equipo_id)=1 and btrim(detalle)<>'')),
 check(estado='pendiente' or asignado_id is not null),
 check(estado<>'resuelta' or (resuelto is not null and minutos is not null))
);
create index on public.solicitudes_trabajo(asignado_id,estado);
create table public.solicitud_historial (
 id uuid primary key default gen_random_uuid(), solicitud_id uuid not null references public.solicitudes_trabajo(id),
 usuario_id uuid not null references public.perfiles(id), creado timestamptz not null default now(), antes jsonb, despues jsonb not null
);
alter table public.solicitudes_trabajo enable row level security;
alter table public.solicitud_historial enable row level security;
revoke all on public.solicitudes_trabajo,public.solicitud_historial from public,anon,authenticated;
grant select on public.solicitudes_trabajo,public.solicitud_historial to authenticated;
create policy lectura on public.solicitudes_trabajo for select to authenticated using(
 (select egeo_privado.sesion_activa()) and (asignado_id=auth.uid() or public.rango(public.rol_actual())>=2));
create policy lectura on public.solicitud_historial for select to authenticated using(
 (select egeo_privado.sesion_activa()) and exists(select 1 from public.solicitudes_trabajo s where s.id=solicitud_id));
-- Cerrar el acceso histórico de operarios a intervenciones ajenas.
drop policy mantenimientos_lectura on public.mantenimientos;
create policy mantenimientos_lectura on public.mantenimientos for select to authenticated
 using(ejecutor_id=auth.uid() or public.rango(public.rol_actual())>=2);

create function public.gestionar_solicitud(p_accion text,p_id uuid,p_datos jsonb default '{}',p_revision integer default null)
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
   select nombre into v_nombre from public.perfiles where id=uid;
   insert into public.mantenimientos(id,registrado_por,registrado_nombre,ejecutor_id,ejecutor_nombre,fecha_ejecucion,detalle,preventivo,minutos)
   select s.id,uid,v_nombre,s.asignado_id,p.nombre,(clock_timestamp() at time zone 'America/Argentina/Buenos_Aires')::date,
    case when s.tipo='molienda' then 'Molienda' else btrim(p_datos->>'resolucion') end,s.preventivo,(p_datos->>'minutos')::integer
   from public.perfiles p where p.id=s.asignado_id;
   update public.solicitudes_trabajo set estado='resuelta',resuelto=clock_timestamp(),resolucion=coalesce(p_datos->>'resolucion',''),
    minutos=(p_datos->>'minutos')::integer,mantenimiento_id=s.id,revision=revision+1 where id=p_id returning * into s;
  else raise exception 'Acción inválida'; end if;
 end if;
 insert into public.solicitud_historial(solicitud_id,usuario_id,antes,despues) values(s.id,uid,anterior,to_jsonb(s));
 return to_jsonb(s);
end $$;
revoke all on function public.gestionar_solicitud(text,uuid,jsonb,integer) from public,anon;
grant execute on function public.gestionar_solicitud(text,uuid,jsonb,integer) to authenticated;
notify pgrst,'reload schema';
commit;
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
  ) from public.mantenimientos m where m.ejecutor_id=auth.uid() or public.rango(public.rol_actual())>=2);
end;
$function$;
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
  if not found or not v_registrante.activo or v_registrante.rol not in ('admin', 'supervisor') then
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
