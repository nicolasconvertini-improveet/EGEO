-- Nueva migración incremental. Aplicar después de 20261029000000_inyectado_ciclos.sql.
-- Nunca editar las migraciones anteriores ni volver a ejecutar el paquete de octubre.
begin;
set local lock_timeout='10s';

create table public.materiales (
 id uuid primary key default gen_random_uuid(),
 codigo text unique not null check(btrim(codigo)<>''),
 nombre text not null check(btrim(nombre)<>''),
 activo boolean not null default true
);
create unique index materiales_nombre_normalizado on public.materiales(lower(btrim(nombre)));
-- Convertir materiales existentes. No se inventan consumos ni nombres.
insert into public.materiales(codigo,nombre)
select 'MAT-'||lpad(row_number() over(order by clave)::text,6,'0'),nombre
from (select lower(btrim(material)) clave,min(btrim(material)) nombre
      from public.moldes where btrim(material)<>'' group by lower(btrim(material))) x;
alter table public.moldes add column material_id uuid references public.materiales(id),
 add column colada_gramos numeric check(colada_gramos>=0 and colada_gramos<'Infinity'::numeric);
update public.moldes m set material_id=x.id from public.materiales x
 where lower(btrim(m.material))=lower(btrim(x.nombre));
create table public.molde_maquinas (
 molde_id uuid not null references public.moldes(id),
 maquina_id uuid not null references public.maquinas(id),
 primary key(molde_id,maquina_id)
);
insert into public.molde_maquinas select id,maquina_id from public.moldes;
create index on public.molde_maquinas(maquina_id);

alter table public.pedidos add column maquina_id uuid references public.maquinas(id),
 add column material_id uuid references public.materiales(id),
 add column material_confirmado boolean not null default false,
 add column requiere_cierre_molde boolean not null default false;
-- Las órdenes existentes quedan con false. No se inventa su montaje ni se altera su snapshot.
create table public.pedido_montajes (
 pedido_id uuid primary key references public.pedidos(id),
 subida_minutos numeric not null check(subida_minutos>=0 and subida_minutos<'Infinity'::numeric),
 calentamiento_minutos numeric not null check(calentamiento_minutos>=0 and calentamiento_minutos<'Infinity'::numeric),
 montado_en timestamptz not null default clock_timestamp(),
 montado_por uuid not null references public.perfiles(id),
 bajada_minutos numeric check(bajada_minutos>=0 and bajada_minutos<'Infinity'::numeric),
 bajado_en timestamptz,
 bajado_por uuid references public.perfiles(id),
 limpieza_confirmada boolean not null default false,
 check((bajada_minutos is null and bajado_en is null and bajado_por is null and not limpieza_confirmada)
    or (bajada_minutos is not null and bajado_en is not null and bajado_por is not null and limpieza_confirmada))
);
do $$ declare t text; begin
 foreach t in array array['materiales','molde_maquinas','pedido_montajes'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy sesion on public.%I as restrictive for all to authenticated using ((select egeo_privado.sesion_activa())) with check ((select egeo_privado.sesion_activa()))',t);
  execute format('create policy lectura on public.%I for select to authenticated using (true)',t);
 end loop;
end $$;
grant insert,update on public.materiales to authenticated;
create policy administracion on public.materiales for all to authenticated
 using(public.rol_actual()='admin') with check(public.rol_actual()='admin');
grant insert(maquina_id,material_id,material_confirmado) on public.pedidos to authenticated;

create or replace function egeo_privado.validar_maquina() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.activo and not new.activo and exists(
  select 1 from public.molde_maquinas mm join public.moldes m on m.id=mm.molde_id
  where mm.maquina_id=old.id and m.activo
 ) then raise exception 'Desactivá o reasigná primero los moldes activos de esta máquina'; end if;
 return new;
end $$;

create or replace function public.guardar_molde(p_id uuid,p_datos jsonb,p_articulos jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare mid uuid:=coalesce(p_id,gen_random_uuid()); ids uuid[]; x jsonb; mat public.materiales%rowtype;
 act boolean:=coalesce((p_datos->>'activo')::boolean,true);
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(mid::text,0));
 if p_datos ? 'unidad_material' and coalesce(p_datos->>'unidad_material','')<>'g' then raise exception 'El material por ciclo se expresa siempre en gramos'; end if;
 if jsonb_typeof(p_datos->'maquinas') is distinct from 'array' then raise exception 'Seleccioná máquinas'; end if;
 select array_agg(distinct v::uuid order by v::uuid) into ids from jsonb_array_elements_text(p_datos->'maquinas') v;
 if coalesce(cardinality(ids),0)=0 then raise exception 'Seleccioná al menos una máquina'; end if;
 perform 1 from public.maquinas where id=any(ids) order by id for share;
 if (select count(*) from public.maquinas where id=any(ids) and (activo or not act))<>cardinality(ids) then
  raise exception 'Seleccioná máquinas válidas y activas';
 end if;
 select * into mat from public.materiales where id=(p_datos->>'material_id')::uuid and (activo or not act) for share;
 if not found then raise exception 'Seleccioná un material activo'; end if;
 if p_datos->>'colada_gramos' is null then raise exception 'Cargá el peso de colada, incluso si es cero'; end if;
 if jsonb_typeof(p_articulos) is distinct from 'array' or jsonb_array_length(p_articulos)=0 then raise exception 'Agregá artículos'; end if;
 insert into public.moldes(id,codigo,maquina_id,material,material_id,colada_gramos,material_ciclo,unidad_material,segundos_ciclo,activo)
 values(mid,btrim(p_datos->>'codigo'),ids[1],mat.nombre,mat.id,(p_datos->>'colada_gramos')::numeric,
  (p_datos->>'material_ciclo')::numeric,'g',(p_datos->>'segundos_ciclo')::numeric,act)
 on conflict(id) do update set codigo=excluded.codigo,maquina_id=excluded.maquina_id,material=excluded.material,
  material_id=excluded.material_id,colada_gramos=excluded.colada_gramos,material_ciclo=excluded.material_ciclo,
  unidad_material='g',segundos_ciclo=excluded.segundos_ciclo,activo=excluded.activo;
 delete from public.molde_maquinas where molde_id=mid;
 insert into public.molde_maquinas select mid,unnest(ids);
 delete from public.molde_articulos where molde_id=mid;
 for x in select * from jsonb_array_elements(p_articulos) loop
  perform 1 from public.articulos where id=(x->>'articulo_id')::uuid and (activo or not act) for share;
  if not found then raise exception 'El artículo no está activo'; end if;
  insert into public.molde_articulos values(mid,(x->>'articulo_id')::uuid,(x->>'unidades_ciclo')::integer);
 end loop;
 return mid;
end $$;

create or replace function egeo_privado.configurar_pedido() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.moldes%rowtype; a public.articulos%rowtype; maq public.maquinas%rowtype; mat public.materiales%rowtype;
begin
 if tg_op='UPDATE' then
  if (new.proceso,new.molde_id,new.articulo_id,new.configuracion,new.maquina_id,new.material_id,new.material_confirmado,new.requiere_cierre_molde) is distinct from (old.proceso,old.molde_id,old.articulo_id,old.configuracion,old.maquina_id,old.material_id,old.material_confirmado,old.requiere_cierre_molde) then
   raise exception 'El proceso y la configuración de una orden son inmutables';
  end if;
  return new;
 end if;
 if new.proceso is null then raise exception 'Seleccioná un proceso'; end if;
 if new.proceso='inyectado' then
  perform pg_advisory_xact_lock(hashtextextended(new.molde_id::text,0));
  select * into m from public.moldes where id=new.molde_id and activo for share;
  if not found then raise exception 'Seleccioná un molde activo'; end if;
  select q.* into maq from public.maquinas q join public.molde_maquinas mm on mm.maquina_id=q.id
   where mm.molde_id=m.id and q.id=new.maquina_id and q.activo for share of q;
  if not found then raise exception 'Seleccioná una máquina activa compatible con el molde'; end if;
  select * into mat from public.materiales where id=new.material_id and activo for share;
  if not found or not new.material_confirmado then raise exception 'Seleccioná y confirmá el material de la orden'; end if;
  if m.colada_gramos is null then raise exception 'Completá el peso de colada del molde'; end if;
  new.requiere_cierre_molde:=true;
  if not exists(select 1 from public.molde_articulos where molde_id=m.id) or exists(
   select 1 from public.molde_articulos ma join public.articulos aa on aa.id=ma.articulo_id where ma.molde_id=m.id and not aa.activo
  ) then raise exception 'El molde debe tener artículos activos'; end if;
  new.configuracion := to_jsonb(m) || jsonb_build_object('maquina_id',maq.id,'maquina_codigo',maq.codigo,
   'maquina_nombre',maq.nombre,'material_id',mat.id,'material_codigo',mat.codigo,'material',mat.nombre);
 else
  new.maquina_id:=null; new.material_id:=null; new.material_confirmado:=false; new.requiere_cierre_molde:=false;
  select * into a from public.articulos where id=new.articulo_id and activo for share;
  if not found then raise exception 'Seleccioná un artículo activo'; end if;
  if coalesce((to_jsonb(a)->>('std_'||new.proceso))::numeric,0)<=0 then raise exception 'El proceso no está habilitado para este artículo'; end if;
  new.configuracion := jsonb_build_object('codigo',a.codigo,'nombre',a.nombre,'segundos_unidad',(to_jsonb(a)->>('std_'||new.proceso))::numeric);
 end if;
 return new;
end $$;

create function egeo_privado.control_molde(p_pedido uuid) returns jsonb
language sql stable set search_path='' as $$
 select to_jsonb(m)||jsonb_build_object('tareas_pendientes',exists(select 1 from public.tareas t where t.pedido_id=m.pedido_id and not t.confirmada),
  'puede_cerrar',public.rol_actual() in ('admin','supervisor')
  or exists(select 1 from public.tareas t where t.pedido_id=m.pedido_id and t.operario_id=auth.uid()))
 from public.pedido_montajes m where m.pedido_id=p_pedido;
$$;
revoke all on function egeo_privado.control_molde(uuid) from public,anon;
grant execute on function egeo_privado.control_molde(uuid) to authenticated;

create or replace view public.v_pedidos with(security_invoker=on) as
select p.id,p.codigo,p.articulo_id,
 coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre,
 coalesce(p.configuracion->>'codigo',a.codigo) as articulo_codigo,
 p.cantidad,p.estado,p.creado,av.avance as ok_acum,av.bruto as ok_bruto,av.etapas_req,av.etapas_completas,
 egeo_privado.scrap_pedido(p.id) as scrap_acum,p.estado_revision,p.proceso,p.molde_id,p.configuracion,
 egeo_privado.articulos_pedido(p.id) articulos,p.maquina_id,p.material_id,p.requiere_cierre_molde,egeo_privado.control_molde(p.id) control_molde
from public.pedidos p left join public.articulos a on a.id=p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;


-- Cada fila representa un tiempo declarado. No se inventan intervalos de reloj.
create view public.v_tiempos_molde with(security_invoker=on) as
 select pedido_id,'Pausa · Subida de molde'::text motivo,subida_minutos minutos,montado_por usuario_id,montado_en registrado_en from public.pedido_montajes
 union all
 select pedido_id,'Pausa · Calentamiento de molde',calentamiento_minutos,montado_por,montado_en from public.pedido_montajes
 union all
 select pedido_id,'Pausa · Bajada de molde',bajada_minutos,bajado_por,bajado_en from public.pedido_montajes where bajado_en is not null;
revoke all on public.v_tiempos_molde from public,anon;
grant select on public.v_tiempos_molde to authenticated;

create function public.iniciar_inyectado(p_pedido uuid,p_montaje jsonb default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.pedidos%rowtype; m public.pedido_montajes%rowtype; av integer;
begin
 perform public.validar_sesion();
 -- Mismo orden de bloqueos que gestionar_tarea: perfil y luego orden.
 perform 1 from public.perfiles where id=auth.uid() for update;
 select * into p from public.pedidos where id=p_pedido for no key update;
 if not found or p.proceso is distinct from 'inyectado' or p.molde_id is null then raise exception 'Orden de inyectado inválida'; end if;
 if p.requiere_cierre_molde then
  if p.estado not in ('pendiente','en_curso') then raise exception 'La orden no está abierta'; end if;
  select avance into av from egeo_privado.avance_pedido_interno(p.id);
  if av>=p.cantidad then raise exception 'Producción completa: corresponde cerrar el molde'; end if;
  select * into m from public.pedido_montajes where pedido_id=p.id;
  if found then
   if m.bajado_en is not null then raise exception 'El molde ya fue retirado'; end if;
   if p_montaje is not null then raise exception 'El montaje ya fue registrado. Actualizá la orden'; end if;
  else
   if (p_montaje->>'confirmado')::boolean is distinct from true then raise exception 'Confirmá la toma y subida del molde'; end if;
   if nullif(btrim(p_montaje->>'subida_minutos'),'') is null or nullif(btrim(p_montaje->>'calentamiento_minutos'),'') is null then
    raise exception 'Cargá los tiempos de subida y calentamiento';
   end if;
   insert into public.pedido_montajes(pedido_id,subida_minutos,calentamiento_minutos,montado_por)
   values(p.id,(p_montaje->>'subida_minutos')::numeric,(p_montaje->>'calentamiento_minutos')::numeric,auth.uid());
  end if;
 end if;
 -- Si falla el inicio de tarea, el montaje también se revierte.
 return public.gestionar_tarea('iniciar',p_pedido=>p.id,p_actividad=>'inyectado');
end $$;

-- Impide iniciar por la RPC anterior o insertar una tarea sin montaje.
create function egeo_privado.exigir_montaje() returns trigger
language plpgsql security definer set search_path='' as $$
declare p public.pedidos%rowtype; av integer;
begin
 select * into p from public.pedidos where id=new.pedido_id for no key update;
 if p.requiere_cierre_molde then
  if not exists(select 1 from public.pedido_montajes where pedido_id=p.id and bajado_en is null) then raise exception 'Falta confirmar y registrar el montaje'; end if;
  select avance into av from egeo_privado.avance_pedido_interno(p.id);
  if av>=p.cantidad then raise exception 'La producción está completa: falta cerrar el molde'; end if;
 end if;
 return new;
end $$;
create trigger exigir_montaje before insert on public.tareas for each row execute function egeo_privado.exigir_montaje();

create or replace function public.recalcular_estado_pedido() returns trigger
language plpgsql security definer set search_path='' as $$
declare pid uuid:=coalesce(new.pedido_id,old.pedido_id); p public.pedidos%rowtype; av integer;
begin
 select * into p from public.pedidos where id=pid for no key update;
 if not found or p.estado in ('cancelado','finalizado','finalizado_pendientes') then return null; end if;
 select avance into av from egeo_privado.avance_pedido_interno(pid);
 update public.pedidos set estado=case
  when av>=p.cantidad and not p.requiere_cierre_molde then 'finalizado'
  when p.estado='en_curso' or exists(select 1 from public.tareas where pedido_id=pid) then 'en_curso'
  else 'pendiente' end where id=pid;
 return null;
end $$;

create function egeo_privado.exigir_cierre_molde() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not old.requiere_cierre_molde then return new; end if;
 if exists(select 1 from public.pedido_montajes where pedido_id=old.id and bajado_en is not null)
  and (new.cantidad is distinct from old.cantidad or (old.estado in ('finalizado','cancelado','finalizado_pendientes') and new.estado in ('pendiente','en_curso'))) then
  raise exception 'El molde ya fue retirado: no se reabre ni amplía esta orden. Creá una nueva';
 end if;
 if new.estado in ('finalizado','finalizado_pendientes') and not exists(
  select 1 from public.pedido_montajes where pedido_id=old.id and bajado_en is not null and limpieza_confirmada
 ) then raise exception 'Registrá la bajada y confirmá la limpieza antes de cerrar'; end if;
 return new;
end $$;
create trigger aa_exigir_cierre_molde before update on public.pedidos for each row execute function egeo_privado.exigir_cierre_molde();

create function public.cerrar_molde(p_pedido uuid,p_revision integer,p_bajada_minutos numeric,p_limpieza boolean) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.pedidos%rowtype; m public.pedido_montajes%rowtype; av integer; u public.perfiles%rowtype;
begin
 perform public.validar_sesion();
 select * into u from public.perfiles where id=auth.uid();
 select * into p from public.pedidos where id=p_pedido for no key update;
 if not found or not p.requiere_cierre_molde then raise exception 'Orden sin control de molde'; end if;
 if u.rol='operario' and not exists(select 1 from public.tareas where pedido_id=p.id and operario_id=u.id) then
  raise exception 'Solo puede cerrar un participante de la orden o un supervisor' using errcode='42501';
 end if;
 select * into m from public.pedido_montajes where pedido_id=p.id for update;
 if not found then raise exception 'No se registró el montaje'; end if;
 if m.bajado_en is not null then
  if m.bajada_minutos=p_bajada_minutos and p_limpieza is true then return p.id; end if;
  raise exception 'El cierre ya fue registrado';
 end if;
 if p.estado_revision is distinct from p_revision or p.estado not in ('pendiente','en_curso') then raise exception 'La orden cambió: actualizá la pantalla'; end if;
 if exists(select 1 from public.tareas where pedido_id=p.id and not confirmada) then raise exception 'Hay tareas abiertas o sin confirmar'; end if;
 select avance into av from egeo_privado.avance_pedido_interno(p.id);
 if av<p.cantidad then raise exception 'Todavía faltan piezas OK: no corresponde bajar el molde'; end if;
 if p_bajada_minutos is null or p_limpieza is distinct from true then raise exception 'Cargá la bajada y confirmá la limpieza'; end if;
 update public.pedido_montajes set bajada_minutos=p_bajada_minutos,bajado_en=clock_timestamp(),bajado_por=u.id,limpieza_confirmada=true where pedido_id=p.id;
 insert into public.pedido_estado_historial(id,pedido_id,estado_anterior,estado_nuevo,accion,revision_anterior,revision_nueva,usuario_id,usuario_nombre,usuario_rol,motivo,origen,detalle_proceso)
 values(gen_random_uuid(),p.id,p.estado,'finalizado','sistema',p.estado_revision,p.estado_revision+1,u.id,u.nombre,u.rol,
 'Bajada de molde y limpieza confirmadas','sistema','Cierre operativo de inyectado');
 update public.pedidos set estado='finalizado' where id=p.id;
 return p.id;
end $$;
revoke all on function public.iniciar_inyectado(uuid,jsonb),public.cerrar_molde(uuid,integer,numeric,boolean) from public,anon;
grant execute on function public.iniciar_inyectado(uuid,jsonb),public.cerrar_molde(uuid,integer,numeric,boolean) to authenticated;
revoke all on function egeo_privado.exigir_montaje(),egeo_privado.exigir_cierre_molde() from public,anon,authenticated;

create or replace function public.indicadores_tablas(p_desde date,p_hasta date,p_articulos uuid[] default null,p_proceso text default '',p_operario uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' set timezone='America/Argentina/Buenos_Aires' as $$
declare resultado jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta) or p_hasta<p_desde or p_hasta-p_desde>92 or p_hasta>current_date
  or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then raise exception 'Elegí un período de hasta 93 días, sin fechas futuras'; end if;
 if (select count(*) from (
   select 1 from public.tareas t join public.pedidos p on p.id=t.pedido_id
   where t.confirmada and t.fin>=p_desde::timestamptz and t.fin<(p_hasta+1)::timestamptz
    and (p_articulos is null or p.articulo_id=any(p_articulos) or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos)))
    and (coalesce(p_proceso,'')='' or t.actividad=p_proceso) and (p_operario is null or t.operario_id=p_operario)
   limit 20001
  ) candidatas)>20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with elegibles as (
  select t.* from public.v_tareas t join public.pedidos p on p.id=t.pedido_id
  where (p_articulos is null or p.articulo_id=any(p_articulos) or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos)))
   and (coalesce(p_proceso,'')='' or t.actividad=p_proceso) and (p_operario is null or t.operario_id=p_operario)
 ), molde_filtrados as (
  select x.* from public.v_tiempos_molde x join public.pedidos p on p.id=x.pedido_id
  where (coalesce(p_proceso,'')='' or p_proceso='inyectado')
   and (p_operario is null or x.usuario_id=p_operario)
   and (p_articulos is null or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos)))
 ), produccion as (
  select r.articulo_id,r.codigo,r.descripcion,sum(r.piezas_ok) ok,sum(r.piezas_scrap) scrap
  from public.v_produccion_articulos r where r.confirmada and r.fin>=p_desde::timestamptz and r.fin<(p_hasta+1)::timestamptz
   and (p_articulos is null or r.articulo_id=any(p_articulos)) and (coalesce(p_proceso,'')='' or r.actividad=p_proceso) and (p_operario is null or r.operario_id=p_operario)
  group by r.articulo_id,r.codigo,r.descripcion
 ), tiempos_base as (
  select 'Producción · '||t.actividad motivo,
   greatest(0,extract(epoch from least(t.fin,(p_hasta+1)::timestamptz)-greatest(t.inicio,p_desde::timestamptz))-
    coalesce((select sum(greatest(0,extract(epoch from least(coalesce(x.fin,t.fin),t.fin,(p_hasta+1)::timestamptz)-greatest(x.inicio,t.inicio,p_desde::timestamptz)))) from public.tarea_pausas x where x.tarea_id=t.id),0)) segundos
  from elegibles t where t.confirmada and t.inicio<(p_hasta+1)::timestamptz and t.fin>p_desde::timestamptz
  union all
  select 'Pausa · '||x.motivo, greatest(0,extract(epoch from least(coalesce(x.fin,statement_timestamp()),(p_hasta+1)::timestamptz)-greatest(x.inicio,p_desde::timestamptz)))
  from public.tarea_pausas x join elegibles t on t.id=x.tarea_id
  where x.inicio<(p_hasta+1)::timestamptz and coalesce(x.fin,statement_timestamp())>p_desde::timestamptz
  union all
  select x.motivo,x.minutos*60 from molde_filtrados x where x.registrado_en>=p_desde::timestamptz and x.registrado_en<(p_hasta+1)::timestamptz
  union all
  select case when s.tipo='molienda' then 'Molienda' when m.preventivo then 'Mantenimiento preventivo' else 'Mantenimiento correctivo' end,m.minutos*60::numeric
  from public.mantenimientos m left join public.solicitudes_trabajo s on s.mantenimiento_id=m.id
  where m.fecha_ejecucion between p_desde and p_hasta
 ), tiempos as (select motivo,sum(segundos) segundos from tiempos_base group by motivo),
 detalles as (
  select t.id,t.pedido_id,t.pedido_codigo,coalesce(t.articulo_id,p.molde_id) articulo_id,
   t.articulo_nombre,coalesce(p.configuracion->>'codigo',a.codigo) articulo_codigo,
   t.actividad,t.operario_id,t.operario_nombre,t.fin::date dia,
   case when p.molde_id is null then t.piezas_ok else coalesce((select sum(r.piezas_ok) from public.tarea_resultados r where r.tarea_id=t.id and (p_articulos is null or r.articulo_id=any(p_articulos))),0) end piezas_ok,
   case when p.molde_id is null then t.piezas_scrap else coalesce((select sum(r.piezas_scrap) from public.tarea_resultados r where r.tarea_id=t.id and (p_articulos is null or r.articulo_id=any(p_articulos))),0) end piezas_scrap,
   t.real_seg,t.std_seg,
   case when p.molde_id is not null then (p.configuracion->>'segundos_ciclo')::numeric
        when p.proceso is not null then (p.configuracion->>'segundos_unidad')::numeric
        else (to_jsonb(a)->>('std_'||t.actividad))::numeric end estandar,
   case when p.proceso is not null then true else t.actividad=case when a.std_embolsado>0 then 'embolsado' when a.std_armado>0 then 'armado' when a.std_rebabado>0 then 'rebabado' when a.std_inyectado>0 then 'inyectado' end end es_ultimo
  from elegibles t join public.pedidos p on p.id=t.pedido_id left join public.articulos a on a.id=p.articulo_id
  where t.confirmada and t.fin>=p_desde::timestamptz and t.fin<(p_hasta+1)::timestamptz
 ), dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 ordenes_elegibles as (
  select p.* from public.pedidos p where p_articulos is null or p.articulo_id=any(p_articulos)
   or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos))
 ), cierres as (
  select h.pedido_id,min(h.creado)::date dia from public.pedido_estado_historial h
  join ordenes_elegibles p on p.id=h.pedido_id where h.estado_nuevo='finalizado' group by h.pedido_id
 ), dias_resumen as (
  select d.dia,
   (select count(*) from detalles t where t.dia=d.dia) tareas,
   coalesce((select sum(t.piezas_ok) from detalles t where t.dia=d.dia and t.es_ultimo),0) piezas,
   coalesce((select sum(t.piezas_ok) from detalles t where t.dia=d.dia),0) ok,
   coalesce((select sum(t.piezas_scrap) from detalles t where t.dia=d.dia),0) scrap,
   coalesce((select sum(greatest(0,extract(epoch from least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))-
    coalesce((select sum(greatest(0,extract(epoch from least(coalesce(x.fin,t.fin),t.fin,(d.dia+1)::timestamptz)-greatest(x.inicio,t.inicio,d.dia::timestamptz)))) from public.tarea_pausas x where x.tarea_id=t.id),0)))
    from elegibles t where t.confirmada and t.inicio<(d.dia+1)::timestamptz and t.fin>d.dia::timestamptz),0) real,
   (select count(*) from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio>=d.dia::timestamptz and x.inicio<(d.dia+1)::timestamptz)+(select count(*) from molde_filtrados x where x.registrado_en>=d.dia::timestamptz and x.registrado_en<(d.dia+1)::timestamptz) pausas,
   coalesce((select sum(greatest(0,extract(epoch from least(coalesce(x.fin,statement_timestamp()),(d.dia+1)::timestamptz)-greatest(x.inicio,d.dia::timestamptz))))
    from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio<(d.dia+1)::timestamptz and coalesce(x.fin,statement_timestamp())>d.dia::timestamptz),0)+coalesce((select sum(x.minutos*60) from molde_filtrados x where x.registrado_en>=d.dia::timestamptz and x.registrado_en<(d.dia+1)::timestamptz),0) pausa_seg,
   (select count(*) from cierres c where c.dia=d.dia) ordenes,
   (select count(*) from public.mantenimientos m where m.fecha_ejecucion=d.dia) mantenimientos,
   coalesce((select sum(m.minutos*60::numeric) from public.mantenimientos m where m.fecha_ejecucion=d.dia),0) mantenimiento_seg,
   coalesce((select sum(m.minutos*60::numeric) from public.mantenimientos m where m.fecha_ejecucion=d.dia and not m.preventivo),0) correctivo_seg
  from dias d
 )

 select jsonb_build_object('desde',p_desde,'hasta',p_hasta,
  'tareas',coalesce((select jsonb_agg(to_jsonb(d) order by d.dia,d.id) from detalles d),'[]'::jsonb),
  'dias',coalesce((select jsonb_agg(to_jsonb(d) order by d.dia) from dias_resumen d),'[]'::jsonb),
  'finalizadas_sin_fecha',(select count(*) from ordenes_elegibles p where p.estado='finalizado' and not exists(select 1 from public.pedido_estado_historial h where h.pedido_id=p.id and h.estado_nuevo='finalizado')),
  'sin_etapas',(select count(*) from detalles where es_ultimo is null),
  'produccion',coalesce((select jsonb_agg(to_jsonb(p) order by p.codigo) from produccion p),'[]'::jsonb),
  'tiempos',coalesce((select jsonb_agg(to_jsonb(t) order by t.motivo) from tiempos t),'[]'::jsonb),
  'total_segundos',coalesce((select sum(segundos) from tiempos),0),
  'catalogo',coalesce((select jsonb_agg(jsonb_build_object('id',id,'codigo',codigo,'nombre',nombre,'categoria',categoria) order by codigo) from public.articulos),'[]'::jsonb),
  'usuarios',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nombre',nombre) order by nombre) from public.perfiles),'[]'::jsonb)
 ) into resultado;
 return resultado;
end $$;


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

  if v_pedido.proceso is not null then
    if v_pedido.molde_id is not null then
      select coalesce(max(ceil(x.ok/pa.unidades_ciclo)),0)::int into v_minimo
      from public.pedido_articulos pa left join lateral (
       select coalesce(sum(r.piezas_ok),0)::numeric ok from public.tarea_resultados r join public.tareas t on t.id=r.tarea_id
       where t.pedido_id=p_pedido and t.confirmada and r.articulo_id=pa.articulo_id
      ) x on true where pa.pedido_id=p_pedido;
    else
      select coalesce(sum(piezas_ok),0)::int into v_minimo from public.tareas where pedido_id=p_pedido and confirmada and actividad=v_pedido.proceso;
    end if;
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
      then case when v_pedido.requiere_cierre_molde then 'en_curso' else 'finalizado' end
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
create or replace function public.exportar_reporte(p_reporte text)
returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare
  v_columnas jsonb;
  v_resultado jsonb;
  v_alcance text;
begin
  perform public.validar_sesion();
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
    v_alcance := 'Pausas de tareas y tiempos declarados de montaje/calentamiento/bajada. Para tiempos declarados, inicio indica la fecha de registro y fin queda vacío.';
    v_columnas := '[{"nombre":"nro_orden","tipo":"text"},{"nombre":"usuario","tipo":"text"},{"nombre":"motivo","tipo":"text"},{"nombre":"inicio","tipo":"text"},{"nombre":"fin","tipo":"text"},{"nombre":"t_total","tipo":"text"}]';
    with base as (
      select pe.codigo nro_orden,coalesce(u.nombre,'—') usuario,p.motivo,
       to_char(p.inicio,'YYYY-MM-DD HH24:MI') inicio,to_char(p.fin,'YYYY-MM-DD HH24:MI') fin,
       to_char(date_trunc('second',p.fin-p.inicio),'HH24:MI:SS') t_total,p.inicio fecha,p.id::text clave
      from public.tarea_pausas p join public.tareas t on t.id=p.tarea_id join public.pedidos pe on pe.id=t.pedido_id
      left join public.perfiles u on u.id=t.operario_id
      union all
      select pe.codigo,coalesce(u.nombre,'—'),x.motivo,to_char(x.registrado_en,'YYYY-MM-DD HH24:MI'),null,
       to_char(make_interval(secs=>(x.minutos*60)::double precision),'HH24:MI:SS'),x.registrado_en,x.pedido_id::text||x.motivo
      from public.v_tiempos_molde x join public.pedidos pe on pe.id=x.pedido_id left join public.perfiles u on u.id=x.usuario_id
    ), f as (
      select nro_orden,usuario,motivo,inicio,fin,t_total,row_number() over(order by fecha desc,clave) orden from base
    )
    select jsonb_build_object('filas',coalesce(jsonb_agg(
      (select jsonb_object_agg(k,v) from jsonb_each_text(to_jsonb(f)-'orden') x(k,v)) order by f.orden),'[]'::jsonb),'total',count(*)::text)
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
             t.codigo codigo_articulo,
             t.descripcion descripcion_articulo,
             t.cantidad_objetivo cantidad_orden,
             row_number() over (order by t.fin desc, t.tarea_id,t.articulo_id) orden
      from public.v_produccion_articulos t
      join public.pedidos p on p.id = t.pedido_id
      join public.articulos a on a.id = t.articulo_id
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
notify pgrst,'reload schema';
commit;
