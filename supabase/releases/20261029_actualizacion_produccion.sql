-- GENERADO por npm run release:sql. No editar manualmente.
-- Proyecto destino esperado: gplitedrfmlakjghfeud. Ver docs/despliegue-supabase.md.
-- No contiene baseline ni semillas ni limpieza de datos de prueba.
-- Ejecutar COMPLETO en una sola consulta. Ante error: ROLLBACK antes de reintentar.
begin;
set local lock_timeout = '10s';
select pg_advisory_xact_lock(hashtextextended('EGEO:release:20261029',0));
-- Solo para la base existente que ya tiene las migraciones históricas 01–19.
do $preflight$
declare missing text;
begin
 select string_agg(name, ', ') into missing from unnest(array[
  'public.perfiles','public.articulos','public.pedidos','public.tareas',
  'public.tarea_pausas','public.mantenimientos','public.pedido_cantidad_historial','public.tarea_auditoria'
 ]) name where to_regclass(name) is null;
 if missing is not null then raise exception 'Falta el esquema histórico: %',missing; end if;
 if to_regprocedure('egeo_privado.sesion_activa()') is null or to_regprocedure('public.validar_sesion()') is null then
  raise exception 'Faltan migraciones históricas de sesiones. Revisar 01–19 antes de continuar';
 end if;
 if to_regclass('public.maquinas') is not null or to_regclass('public.moldes') is not null
    or to_regclass('public.solicitudes_trabajo') is not null then
  raise exception 'Hay cambios QA aplicados previamente. No repetir este paquete: revisar las migraciones pendientes';
 end if;
end $preflight$;

-- Migración: 20261028000100_procesos_moldes.sql
-- Nuevas órdenes por proceso; legado sin reinterpretación de cantidades.

create table public.maquinas (
 id uuid primary key default gen_random_uuid(), codigo text unique not null check(btrim(codigo)<>''),
 nombre text not null check(btrim(nombre)<>''), activo boolean not null default true
);
create table public.equipos (like public.maquinas including all);
create table public.moldes (
 id uuid primary key default gen_random_uuid(), codigo text unique not null check(btrim(codigo)<>''),
 maquina_id uuid not null references public.maquinas(id), material text not null check(btrim(material)<>''),
 material_ciclo numeric not null check(material_ciclo>0), unidad_material text not null check(btrim(unidad_material)<>''),
 segundos_ciclo numeric not null check(segundos_ciclo>0), activo boolean not null default true
);
create table public.molde_articulos (
 molde_id uuid not null references public.moldes(id), articulo_id uuid not null references public.articulos(id),
 unidades_ciclo integer not null check(unidades_ciclo>0), primary key(molde_id,articulo_id)
);
alter table public.pedidos alter column articulo_id drop not null;
alter table public.pedidos add column proceso text check(proceso in ('inyectado','rebabado','armado','embolsado')),
 add column molde_id uuid references public.moldes(id), add column configuracion jsonb;
alter table public.pedidos add constraint pedido_destino check (
 (proceso is null and molde_id is null and articulo_id is not null) or
 (proceso='inyectado' and molde_id is not null and articulo_id is null) or
 (proceso in ('rebabado','armado','embolsado') and articulo_id is not null and molde_id is null)
);
create table public.pedido_articulos (
 pedido_id uuid not null references public.pedidos(id) on delete cascade,
 articulo_id uuid not null references public.articulos(id), codigo text not null, nombre text not null,
 unidades_ciclo integer not null check(unidades_ciclo>0), primary key(pedido_id,articulo_id)
);
create table public.tarea_resultados (
 tarea_id uuid not null references public.tareas(id) on delete cascade,
 articulo_id uuid not null references public.articulos(id), piezas_ok integer not null check(piezas_ok>=0),
 piezas_scrap integer not null check(piezas_scrap>=0), primary key(tarea_id,articulo_id)
);
create index on public.moldes(maquina_id);
create index on public.tarea_resultados(articulo_id);

-- Nuevos catálogos: sesión vigente y escritura administrativa.
do $$ declare tabla text; begin
 foreach tabla in array array['maquinas','equipos','moldes','molde_articulos','pedido_articulos','tarea_resultados'] loop
  execute format('alter table public.%I enable row level security',tabla);
  execute format('revoke all on public.%I from public, anon, authenticated',tabla);
  execute format('grant select on public.%I to authenticated',tabla);
  execute format('create policy sesion on public.%I as restrictive for all to authenticated using ((select egeo_privado.sesion_activa())) with check ((select egeo_privado.sesion_activa()))',tabla);
  if tabla='tarea_resultados' then
   execute format('create policy lectura on public.%I for select to authenticated using (exists(select 1 from public.tareas t where t.id=tarea_id))',tabla);
  else
   execute format('create policy lectura on public.%I for select to authenticated using (true)',tabla);
  end if;
 end loop;
end $$;
grant insert,update on public.maquinas,public.equipos to authenticated;
create policy administracion on public.maquinas for all to authenticated using(public.rol_actual()='admin') with check(public.rol_actual()='admin');
create policy administracion on public.equipos for all to authenticated using(public.rol_actual()='admin') with check(public.rol_actual()='admin');

create function egeo_privado.validar_maquina() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.activo and not new.activo and exists(select 1 from public.moldes where maquina_id=old.id and activo) then
  raise exception 'Desactivá o reasigná primero los moldes activos de esta máquina';
 end if;
 return new;
end $$;
create trigger validar_maquina before update on public.maquinas for each row execute function egeo_privado.validar_maquina();

create function public.guardar_molde(p_id uuid,p_datos jsonb,p_articulos jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare mid uuid := coalesce(p_id,gen_random_uuid()); x jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(mid::text,0));
 perform 1 from public.maquinas where id=(p_datos->>'maquina_id')::uuid and (activo or not (p_datos->>'activo')::boolean) for share;
 if not found then raise exception 'Seleccioná una máquina activa'; end if;
 if jsonb_typeof(p_articulos)<>'array' or jsonb_array_length(p_articulos)=0 then raise exception 'Agregá al menos un artículo'; end if;
 insert into public.moldes(id,codigo,maquina_id,material,material_ciclo,unidad_material,segundos_ciclo,activo)
 values(mid,btrim(p_datos->>'codigo'),(p_datos->>'maquina_id')::uuid,btrim(p_datos->>'material'),
 (p_datos->>'material_ciclo')::numeric,btrim(p_datos->>'unidad_material'),(p_datos->>'segundos_ciclo')::numeric,(p_datos->>'activo')::boolean)
 on conflict(id) do update set codigo=excluded.codigo,maquina_id=excluded.maquina_id,material=excluded.material,
 material_ciclo=excluded.material_ciclo,unidad_material=excluded.unidad_material,segundos_ciclo=excluded.segundos_ciclo,activo=excluded.activo;
 delete from public.molde_articulos where molde_id=mid;
 for x in select * from jsonb_array_elements(p_articulos) loop
  perform 1 from public.articulos where id=(x->>'articulo_id')::uuid and (activo or not (p_datos->>'activo')::boolean) for share;
  if not found then raise exception 'El artículo no está activo'; end if;
  insert into public.molde_articulos values(mid,(x->>'articulo_id')::uuid,(x->>'unidades_ciclo')::integer);
 end loop;
 return mid;
end $$;

create function egeo_privado.configurar_pedido() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.moldes%rowtype; a public.articulos%rowtype;
begin
 if tg_op='UPDATE' then
  if (new.proceso,new.molde_id,new.articulo_id,new.configuracion) is distinct from (old.proceso,old.molde_id,old.articulo_id,old.configuracion) then
   raise exception 'El proceso y la configuración de una orden son inmutables';
  end if;
  return new;
 end if;
 if new.proceso is null then raise exception 'Seleccioná un proceso'; end if;
 if new.proceso='inyectado' then
  perform pg_advisory_xact_lock(hashtextextended(new.molde_id::text,0));
  select * into m from public.moldes where id=new.molde_id and activo for share;
  if not found then raise exception 'Seleccioná un molde activo'; end if;
  perform 1 from public.maquinas where id=m.maquina_id and activo for share;
  if not found then raise exception 'La máquina no está activa'; end if;
  if not exists(select 1 from public.molde_articulos where molde_id=m.id) or exists(
   select 1 from public.molde_articulos ma join public.articulos a on a.id=ma.articulo_id where ma.molde_id=m.id and not a.activo
  ) then raise exception 'El molde debe tener artículos activos'; end if;
  new.configuracion := to_jsonb(m) || jsonb_build_object('maquina_codigo',(select codigo from public.maquinas where id=m.maquina_id));
 else
  select * into a from public.articulos where id=new.articulo_id and activo for share;
  if not found then raise exception 'Seleccioná un artículo activo'; end if;
  if coalesce((to_jsonb(a)->>('std_'||new.proceso))::numeric,0)<=0 then raise exception 'El proceso no está habilitado para este artículo'; end if;
  new.configuracion := jsonb_build_object('codigo',a.codigo,'nombre',a.nombre,'segundos_unidad',(to_jsonb(a)->>('std_'||new.proceso))::numeric);
 end if;
 return new;
end $$;
create trigger configurar_pedido before insert or update on public.pedidos for each row execute function egeo_privado.configurar_pedido();
create function egeo_privado.copiar_articulos_pedido() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.molde_id is not null then
  insert into public.pedido_articulos select new.id,a.id,a.codigo,a.nombre,ma.unidades_ciclo
   from public.molde_articulos ma join public.articulos a on a.id=ma.articulo_id where ma.molde_id=new.molde_id;
 end if;
 return new;
end $$;
create trigger copiar_articulos after insert on public.pedidos for each row execute function egeo_privado.copiar_articulos_pedido();

-- El cálculo previo queda privado para órdenes históricas multietapa.
alter function egeo_privado.avance_pedido_interno(uuid) rename to avance_pedido_legado;
create function egeo_privado.avance_pedido_interno(p_pedido uuid)
returns table(avance int,bruto int,etapas_req int,etapas_completas int)
language plpgsql stable security definer set search_path='' as $$
declare p public.pedidos%rowtype;
begin
 select * into p from public.pedidos where id=p_pedido;
 if p.proceso is null then return query select * from egeo_privado.avance_pedido_legado(p_pedido); return; end if;
 if p.molde_id is null then
  select coalesce(sum(t.piezas_ok),0)::int into avance from public.tareas t where t.pedido_id=p.id and t.confirmada and t.actividad=p.proceso;
  bruto:=avance; etapas_req:=1; etapas_completas:=case when avance>=p.cantidad then 1 else 0 end; return next;
 else
  return query select coalesce(min(floor(x.ok/pa.unidades_ciclo)),0)::int, coalesce(sum(x.ok),0)::int,
   count(*)::int, count(*) filter(where x.ok>=p.cantidad::numeric*pa.unidades_ciclo)::int
  from public.pedido_articulos pa left join lateral (
   select coalesce(sum(r.piezas_ok),0)::numeric ok from public.tarea_resultados r join public.tareas t on t.id=r.tarea_id
   where t.pedido_id=p.id and t.confirmada and r.articulo_id=pa.articulo_id
  ) x on true where pa.pedido_id=p.id;
 end if;
end $$;
revoke all on function egeo_privado.avance_pedido_interno(uuid) from public,anon,authenticated;
-- Rebind: las funciones SQL conservan el OID de funciones renombradas.
create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int,bruto int,etapas_req int,etapas_completas int)
language plpgsql stable security definer set search_path='' as $$
begin perform public.validar_sesion(); return query select * from egeo_privado.avance_pedido_interno(p_pedido); end $$;

create or replace view public.v_pedidos with(security_invoker=on) as
select p.id,p.codigo,p.articulo_id,
 coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre,
 coalesce(p.configuracion->>'codigo',a.codigo) as articulo_codigo,
 p.cantidad,p.estado,p.creado,av.avance as ok_acum,av.bruto as ok_bruto,av.etapas_req,av.etapas_completas,
 egeo_privado.scrap_pedido(p.id) as scrap_acum,p.estado_revision,p.proceso,p.molde_id,p.configuracion,
 coalesce((select jsonb_agg(to_jsonb(pa) order by pa.codigo) from public.pedido_articulos pa where pa.pedido_id=p.id),'[]'::jsonb) articulos
from public.pedidos p left join public.articulos a on a.id=p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;

create function egeo_privado.validar_proceso_tarea() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.pedidos%rowtype;
begin
 select * into p from public.pedidos where id=new.pedido_id;
 if p.proceso is not null and p.proceso<>new.actividad then raise exception 'La tarea debe usar el proceso de la orden'; end if;
 if p.molde_id is not null and new.confirmada then
  if (select count(*) from public.tarea_resultados where tarea_id=new.id)<>(select count(*) from public.pedido_articulos where pedido_id=p.id)
    or exists(select 1 from public.tarea_resultados r where r.tarea_id=new.id and not exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=r.articulo_id))
    or new.piezas_ok<>(select coalesce(sum(piezas_ok),0) from public.tarea_resultados where tarea_id=new.id)
    or new.piezas_scrap<>(select coalesce(sum(piezas_scrap),0) from public.tarea_resultados where tarea_id=new.id) then
   raise exception 'Registrá las cantidades por cada artículo del molde';
  end if;
 end if;
 return new;
end $$;
create trigger validar_proceso before insert or update on public.tareas for each row execute function egeo_privado.validar_proceso_tarea();

create function public.confirmar_tarea_molde(p_tarea uuid,p_revision integer,p_resultados jsonb,p_observaciones text default '') returns uuid
language plpgsql security definer set search_path='' as $$
declare t public.tareas%rowtype; x jsonb; vok integer; vscrap integer;
begin
 perform public.validar_sesion();
 perform 1 from public.perfiles where id=auth.uid() for update;
 select * into t from public.tareas where id=p_tarea and operario_id=auth.uid() for update;
 if not found then raise exception 'La tarea no te pertenece' using errcode='42501'; end if;
 if not exists(select 1 from public.pedidos where id=t.pedido_id and molde_id is not null) then raise exception 'La orden no usa molde'; end if;
 if jsonb_typeof(p_resultados)<>'array' then raise exception 'Resultados inválidos'; end if;
 if t.confirmada then
  if t.observaciones=btrim(coalesce(p_observaciones,'')) and
   (select jsonb_agg(jsonb_build_object('articulo_id',r.articulo_id,'piezas_ok',r.piezas_ok,'piezas_scrap',r.piezas_scrap) order by r.articulo_id) from public.tarea_resultados r where tarea_id=t.id)
    =(select jsonb_agg(value order by value->>'articulo_id') from jsonb_array_elements(p_resultados)) then return t.id; end if;
  raise exception 'La tarea ya fue confirmada con otros valores';
 end if;
 if t.revision is distinct from p_revision then raise exception 'La tarea cambió; actualizá la pantalla'; end if;
 delete from public.tarea_resultados where tarea_id=t.id;
 for x in select * from jsonb_array_elements(p_resultados) loop
  insert into public.tarea_resultados values(t.id,(x->>'articulo_id')::uuid,(x->>'piezas_ok')::int,(x->>'piezas_scrap')::int);
 end loop;
 select sum(piezas_ok)::int,sum(piezas_scrap)::int into vok,vscrap from public.tarea_resultados where tarea_id=t.id;
 return public.gestionar_tarea('confirmar',p_tarea=>t.id,p_revision=>p_revision,p_ok=>vok,p_scrap=>vscrap,p_observaciones=>p_observaciones);
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
    if v_p.proceso is not null and v_p.proceso is distinct from p_actividad then
      raise exception 'La actividad debe coincidir con el proceso de la orden';
    end if;
    if v_p.molde_id is not null then
      v_a.activo := true;
      v_std := (v_p.configuracion->>'segundos_ciclo')::numeric;
    elsif v_p.proceso is not null then
      v_std := (v_p.configuracion->>'segundos_unidad')::numeric;
    end if;
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

create or replace view public.v_tareas with (security_invoker = on) as
select t.id, t.pedido_id, p.codigo as pedido_codigo, p.articulo_id,
       coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre, t.actividad,
       coalesce(pe.nombre, '—') as operario_nombre, t.operario_id,
       t.inicio, t.fin, t.piezas_ok, t.piezas_scrap, t.creado, t.confirmada,
       case when t.fin is null then null else
         greatest(0, floor(extract(epoch from (t.fin - t.inicio))
                          - pausas.segundos))::int end as real_seg,
       (case when p.molde_id is not null then (p.configuracion->>'segundos_ciclo')::numeric * coalesce((select min(r.piezas_ok::numeric/pa.unidades_ciclo) from public.tarea_resultados r join public.pedido_articulos pa on pa.pedido_id=p.id and pa.articulo_id=r.articulo_id where r.tarea_id=t.id),0) when p.proceso is not null then t.piezas_ok*(p.configuracion->>'segundos_unidad')::numeric else t.piezas_ok * (case t.actividad
          when 'inyectado' then a.std_inyectado
          when 'rebabado' then a.std_rebabado
          when 'armado' then a.std_armado
          when 'embolsado' then a.std_embolsado end) end)::numeric as std_seg,
       t.observaciones, t.revision,
       greatest(0, floor(extract(epoch from
         (coalesce(t.fin, statement_timestamp()) - t.inicio))))::int as total_seg,
       greatest(0, floor(pausas.segundos))::int as pausa_seg,
       abierta.id as pausa_id, abierta.inicio as pausa_inicio,
       abierta.motivo as pausa_motivo,
       statement_timestamp() as servidor_ahora, p.molde_id, p.proceso, coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('codigo',pa.codigo,'nombre',pa.nombre) order by pa.codigo) from public.tarea_resultados r join public.pedido_articulos pa on pa.pedido_id=p.id and pa.articulo_id=r.articulo_id where r.tarea_id=t.id),'[]'::jsonb) as resultados
from public.tareas t
join public.pedidos p on p.id = t.pedido_id
left join public.articulos a on a.id = p.articulo_id
left join public.perfiles pe on pe.id = t.operario_id
left join lateral (
  select coalesce(sum(extract(epoch from
    (coalesce(x.fin, t.fin, statement_timestamp()) - x.inicio))), 0) as segundos
  from public.tarea_pausas x where x.tarea_id = t.id
) pausas on true
left join public.tarea_pausas abierta
  on abierta.tarea_id = t.id and abierta.fin is null;
revoke all on function public.guardar_molde(uuid,jsonb,jsonb),public.confirmar_tarea_molde(uuid,integer,jsonb,text) from public,anon;
grant execute on function public.guardar_molde(uuid,jsonb,jsonb),public.confirmar_tarea_molde(uuid,integer,jsonb,text) to authenticated;
notify pgrst,'reload schema';

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


-- Migración: 20261028000200_solicitudes.sql

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


-- Migración: 20261028000300_indicadores.sql

create view public.v_produccion_articulos with(security_invoker=on) as
 select t.id tarea_id,t.pedido_id,t.pedido_codigo,t.actividad,t.operario_id,t.operario_nombre,t.inicio,t.fin,t.confirmada,
 p.articulo_id,coalesce(p.configuracion->>'codigo',a.codigo) codigo,coalesce(p.configuracion->>'nombre',a.nombre) descripcion,
 t.piezas_ok,t.piezas_scrap,p.cantidad cantidad_objetivo
 from public.v_tareas t join public.pedidos p on p.id=t.pedido_id left join public.articulos a on a.id=p.articulo_id
 where p.molde_id is null
 union all
 select t.id,t.pedido_id,t.pedido_codigo,t.actividad,t.operario_id,t.operario_nombre,t.inicio,t.fin,t.confirmada,
 r.articulo_id,pa.codigo,pa.nombre,r.piezas_ok,r.piezas_scrap,(p.cantidad::bigint*pa.unidades_ciclo)::integer
 from public.v_tareas t join public.pedidos p on p.id=t.pedido_id join public.tarea_resultados r on r.tarea_id=t.id
 join public.pedido_articulos pa on pa.pedido_id=t.pedido_id and pa.articulo_id=r.articulo_id;
revoke all on public.v_produccion_articulos from public,anon;
grant select on public.v_produccion_articulos to authenticated;

create function public.indicadores_tablas(p_desde date,p_hasta date,p_articulos uuid[] default null,p_proceso text default '',p_operario uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' set timezone='America/Argentina/Buenos_Aires' as $$
declare resultado jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta) or p_hasta<p_desde or p_hasta-p_desde>92 or p_hasta>current_date
  or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then raise exception 'Elegí un período de hasta 93 días, sin fechas futuras'; end if;
 with elegibles as (
  select t.* from public.v_tareas t join public.pedidos p on p.id=t.pedido_id
  where (p_articulos is null or p.articulo_id=any(p_articulos) or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos)))
   and (coalesce(p_proceso,'')='' or t.actividad=p_proceso) and (p_operario is null or t.operario_id=p_operario)
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
  select case when s.tipo='molienda' then 'Molienda' when m.preventivo then 'Mantenimiento preventivo' else 'Mantenimiento correctivo' end,m.minutos*60::numeric
  from public.mantenimientos m left join public.solicitudes_trabajo s on s.mantenimiento_id=m.id
  where m.fecha_ejecucion between p_desde and p_hasta and (p_operario is null or m.ejecutor_id=p_operario)
 ), tiempos as (select motivo,sum(segundos) segundos from tiempos_base group by motivo)
 select jsonb_build_object('desde',p_desde,'hasta',p_hasta,
  'produccion',coalesce((select jsonb_agg(to_jsonb(p) order by p.codigo) from produccion p),'[]'::jsonb),
  'tiempos',coalesce((select jsonb_agg(to_jsonb(t) order by t.motivo) from tiempos t),'[]'::jsonb),
  'total_segundos',coalesce((select sum(segundos) from tiempos),0),
  'catalogo',coalesce((select jsonb_agg(jsonb_build_object('id',id,'codigo',codigo,'nombre',nombre,'categoria',categoria) order by codigo) from public.articulos),'[]'::jsonb),
  'usuarios',coalesce((select jsonb_agg(jsonb_build_object('id',id,'nombre',nombre) order by nombre) from public.perfiles),'[]'::jsonb)
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_tablas(date,date,uuid[],text,uuid) from public,anon;
grant execute on function public.indicadores_tablas(date,date,uuid[],text,uuid) to authenticated;

-- Correcciones atómicas del detalle; reutilizar validaciones y auditoría existentes.
create function public.admin_editar_tarea_molde(p_tarea uuid,p_revision integer,p_inicio timestamptz,p_fin timestamptz,p_resultados jsonb,p_observaciones text,p_motivo text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.tareas%rowtype; antes jsonb; resultado jsonb; x jsonb; u public.perfiles%rowtype;
begin
 u:=egeo_privado.exigir_admin(p_motivo);
 select * into t from public.tareas where id=p_tarea for update;
 if not found or not t.confirmada or t.revision is distinct from p_revision then raise exception 'La tarea cambió o no está confirmada'; end if;
 if not exists(select 1 from public.pedidos where id=t.pedido_id and molde_id is not null) then raise exception 'La tarea no corresponde a molde'; end if;
 select jsonb_agg(to_jsonb(r)) into antes from public.tarea_resultados r where tarea_id=t.id;
 delete from public.tarea_resultados where tarea_id=t.id;
 for x in select * from jsonb_array_elements(p_resultados) loop
  insert into public.tarea_resultados values(t.id,(x->>'articulo_id')::uuid,(x->>'piezas_ok')::integer,(x->>'piezas_scrap')::integer);
 end loop;
 resultado:=public.admin_editar_tarea(t.id,p_revision,p_inicio,p_fin,
  (select sum(piezas_ok)::integer from public.tarea_resultados where tarea_id=t.id),
  (select sum(piezas_scrap)::integer from public.tarea_resultados where tarea_id=t.id),p_observaciones,p_motivo);
 insert into public.tarea_auditoria(tarea_id,accion,antes,despues,motivo,usuario_id,usuario_nombre)
 values(t.id,'editar_tarea',jsonb_build_object('resultados',antes),jsonb_build_object('resultados',p_resultados),p_motivo,u.id,u.nombre);
 return resultado;
end $$;
revoke all on function public.admin_editar_tarea_molde(uuid,integer,timestamptz,timestamptz,jsonb,text,text) from public,anon;
grant execute on function public.admin_editar_tarea_molde(uuid,integer,timestamptz,timestamptz,jsonb,text,text) to authenticated;
notify pgrst,'reload schema';


-- Migración: 20261028000400_permisos_ordenes.sql

grant insert(proceso,molde_id) on public.pedidos to authenticated;
-- Todas las vistas nuevas siguen RLS; las funciones de aplicación verifican sesión.
revoke all on public.v_pedidos,public.v_tareas from public,anon;
grant select on public.v_pedidos,public.v_tareas to authenticated;


-- Migración: 20261028000500_validaciones_exportacion.sql

create or replace function egeo_privado.configurar_pedido() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.moldes%rowtype; a public.articulos%rowtype;
begin
 if tg_op='UPDATE' then
  if (new.proceso,new.molde_id,new.articulo_id,new.configuracion) is distinct from (old.proceso,old.molde_id,old.articulo_id,old.configuracion) then
   raise exception 'El proceso y la configuración de una orden son inmutables';
  end if;
  return new;
 end if;
 if new.proceso is null then raise exception 'Seleccioná un proceso'; end if;
 if new.proceso='inyectado' then
  perform pg_advisory_xact_lock(hashtextextended(new.molde_id::text,0));
  select * into m from public.moldes where id=new.molde_id and activo for share;
  if not found then raise exception 'Seleccioná un molde activo'; end if;
  perform 1 from public.maquinas where id=m.maquina_id and activo for share;
  if not found then raise exception 'La máquina no está activa'; end if;
  if not exists(select 1 from public.molde_articulos where molde_id=m.id) or exists(
   select 1 from public.molde_articulos ma join public.articulos aa on aa.id=ma.articulo_id where ma.molde_id=m.id and not aa.activo
  ) then raise exception 'El molde debe tener artículos activos'; end if;
  new.configuracion := to_jsonb(m) || jsonb_build_object('maquina_codigo',(select codigo from public.maquinas where id=m.maquina_id));
 else
  select * into a from public.articulos where id=new.articulo_id and activo for share;
  if not found then raise exception 'Seleccioná un artículo activo'; end if;
  if coalesce((to_jsonb(a)->>('std_'||new.proceso))::numeric,0)<=0 then raise exception 'El proceso no está habilitado para este artículo'; end if;
  new.configuracion := jsonb_build_object('codigo',a.codigo,'nombre',a.nombre,'segundos_unidad',(to_jsonb(a)->>('std_'||new.proceso))::numeric);
 end if;
 return new;
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


-- Migración: 20261028000600_avance_articulos.sql

create function egeo_privado.articulos_pedido(p_pedido uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform public.validar_sesion();
 return coalesce((select jsonb_agg(to_jsonb(pa)||jsonb_build_object('ok',coalesce(x.ok,0),'scrap',coalesce(x.scrap,0)) order by pa.codigo)
 from public.pedido_articulos pa left join lateral(
  select sum(r.piezas_ok) ok,sum(r.piezas_scrap) scrap from public.tarea_resultados r join public.tareas t on t.id=r.tarea_id
  where t.pedido_id=pa.pedido_id and t.confirmada and r.articulo_id=pa.articulo_id
 ) x on true where pa.pedido_id=p_pedido),'[]'::jsonb);
end $$;
revoke all on function egeo_privado.articulos_pedido(uuid) from public,anon;
grant execute on function egeo_privado.articulos_pedido(uuid) to authenticated;
create or replace view public.v_pedidos with(security_invoker=on) as
select p.id,p.codigo,p.articulo_id,
 coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre,
 coalesce(p.configuracion->>'codigo',a.codigo) as articulo_codigo,
 p.cantidad,p.estado,p.creado,av.avance as ok_acum,av.bruto as ok_bruto,av.etapas_req,av.etapas_completas,
 egeo_privado.scrap_pedido(p.id) as scrap_acum,p.estado_revision,p.proceso,p.molde_id,p.configuracion,
 egeo_privado.articulos_pedido(p.id) articulos
from public.pedidos p left join public.articulos a on a.id=p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;
notify pgrst,'reload schema';

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
    values (v_t.id, 'eliminar_tarea', to_jsonb(v_t) || jsonb_build_object('pausas', v_pausas, 'resultados', (select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) from public.tarea_resultados r where r.tarea_id=v_t.id)),
            btrim(p_motivo), v_u.id, v_u.nombre);
  delete from public.tareas where id = v_t.id;   -- el trigger recalcula el estado de la orden
  return v_t.id;
end $$;


-- Migración: 20261028000700_exportacion_observaciones.sql

create or replace view public.v_produccion_articulos with(security_invoker=on) as
 select t.id tarea_id,t.pedido_id,t.pedido_codigo,t.actividad,t.operario_id,t.operario_nombre,t.inicio,t.fin,t.confirmada,
 p.articulo_id,coalesce(p.configuracion->>'codigo',a.codigo) codigo,coalesce(p.configuracion->>'nombre',a.nombre) descripcion,
 t.piezas_ok,t.piezas_scrap,p.cantidad cantidad_objetivo,t.observaciones
 from public.v_tareas t join public.pedidos p on p.id=t.pedido_id left join public.articulos a on a.id=p.articulo_id
 where p.molde_id is null
 union all
 select t.id,t.pedido_id,t.pedido_codigo,t.actividad,t.operario_id,t.operario_nombre,t.inicio,t.fin,t.confirmada,
 r.articulo_id,pa.codigo,pa.nombre,r.piezas_ok,r.piezas_scrap,(p.cantidad::bigint*pa.unidades_ciclo)::integer,t.observaciones
 from public.v_tareas t join public.pedidos p on p.id=t.pedido_id join public.tarea_resultados r on r.tarea_id=t.id
 join public.pedido_articulos pa on pa.pedido_id=t.pedido_id and pa.articulo_id=r.articulo_id;
notify pgrst,'reload schema';


-- Migración: 20261028000800_observaciones_molienda.sql
-- Preserva las observaciones de molienda al resolver y exportar intervenciones.

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


-- Migración: 20261028000900_restaurar_indicadores.sql
-- Recuperar el contrato de resumen, filtros y comparación original junto a las tablas nuevas.

create or replace function public.indicadores_tablas(p_desde date,p_hasta date,p_articulos uuid[] default null,p_proceso text default '',p_operario uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' set timezone='America/Argentina/Buenos_Aires' as $$
declare resultado jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta) or p_hasta<p_desde or p_hasta-p_desde>92 or p_hasta>current_date
  or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then raise exception 'Elegí un período de hasta 93 días, sin fechas futuras'; end if;
 with elegibles as (
  select t.* from public.v_tareas t join public.pedidos p on p.id=t.pedido_id
  where (p_articulos is null or p.articulo_id=any(p_articulos) or exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=any(p_articulos)))
   and (coalesce(p_proceso,'')='' or t.actividad=p_proceso) and (p_operario is null or t.operario_id=p_operario)
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
  select case when s.tipo='molienda' then 'Molienda' when m.preventivo then 'Mantenimiento preventivo' else 'Mantenimiento correctivo' end,m.minutos*60::numeric
  from public.mantenimientos m left join public.solicitudes_trabajo s on s.mantenimiento_id=m.id
  where m.fecha_ejecucion between p_desde and p_hasta
 ), tiempos as (select motivo,sum(segundos) segundos from tiempos_base group by motivo),
 detalles as (
  select t.id,t.pedido_id,t.pedido_codigo,coalesce(t.articulo_id,p.molde_id) articulo_id,
   t.articulo_nombre,coalesce(p.configuracion->>'codigo',a.codigo) articulo_codigo,
   t.actividad,t.operario_id,t.operario_nombre,t.fin::date dia,t.piezas_ok,t.piezas_scrap,t.real_seg,t.std_seg,
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
   (select count(*) from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio>=d.dia::timestamptz and x.inicio<(d.dia+1)::timestamptz) pausas,
   coalesce((select sum(greatest(0,extract(epoch from least(coalesce(x.fin,statement_timestamp()),(d.dia+1)::timestamptz)-greatest(x.inicio,d.dia::timestamptz))))
    from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio<(d.dia+1)::timestamptz and coalesce(x.fin,statement_timestamp())>d.dia::timestamptz),0) pausa_seg,
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
notify pgrst,'reload schema';


-- Migración: 20261028001000_detalle_indicadores_filtros.sql
-- Mantener el límite original y contar solo artículos seleccionados en el resumen de moldes.

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
   (select count(*) from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio>=d.dia::timestamptz and x.inicio<(d.dia+1)::timestamptz) pausas,
   coalesce((select sum(greatest(0,extract(epoch from least(coalesce(x.fin,statement_timestamp()),(d.dia+1)::timestamptz)-greatest(x.inicio,d.dia::timestamptz))))
    from public.tarea_pausas x join elegibles t on t.id=x.tarea_id where x.inicio<(d.dia+1)::timestamptz and coalesce(x.fin,statement_timestamp())>d.dia::timestamptz),0) pausa_seg,
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
notify pgrst,'reload schema';


-- Migración: 20261028001100_material_gramos.sql
-- Fijar gramos en el catálogo; las configuraciones históricas de órdenes se conservan.

alter table public.moldes alter column unidad_material set default 'g';
alter table public.moldes add constraint moldes_unidad_gramos check(unidad_material='g');
create or replace function public.guardar_molde(p_id uuid,p_datos jsonb,p_articulos jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare mid uuid := coalesce(p_id,gen_random_uuid()); x jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 if p_datos ? 'unidad_material' and coalesce(p_datos->>'unidad_material','') <> 'g' then
  raise exception 'El material por ciclo se expresa siempre en gramos (g)';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(mid::text,0));
 perform 1 from public.maquinas where id=(p_datos->>'maquina_id')::uuid and (activo or not (p_datos->>'activo')::boolean) for share;
 if not found then raise exception 'Seleccioná una máquina activa'; end if;
 if jsonb_typeof(p_articulos)<>'array' or jsonb_array_length(p_articulos)=0 then raise exception 'Agregá al menos un artículo'; end if;
 insert into public.moldes(id,codigo,maquina_id,material,material_ciclo,unidad_material,segundos_ciclo,activo)
 values(mid,btrim(p_datos->>'codigo'),(p_datos->>'maquina_id')::uuid,btrim(p_datos->>'material'),
 (p_datos->>'material_ciclo')::numeric,'g',(p_datos->>'segundos_ciclo')::numeric,(p_datos->>'activo')::boolean)
 on conflict(id) do update set codigo=excluded.codigo,maquina_id=excluded.maquina_id,material=excluded.material,
 material_ciclo=excluded.material_ciclo,unidad_material=excluded.unidad_material,segundos_ciclo=excluded.segundos_ciclo,activo=excluded.activo;
 delete from public.molde_articulos where molde_id=mid;
 for x in select * from jsonb_array_elements(p_articulos) loop
  perform 1 from public.articulos where id=(x->>'articulo_id')::uuid and (activo or not (p_datos->>'activo')::boolean) for share;
  if not found then raise exception 'El artículo no está activo'; end if;
  insert into public.molde_articulos values(mid,(x->>'articulo_id')::uuid,(x->>'unidades_ciclo')::integer);
 end loop;
 return mid;
end $$;
notify pgrst,'reload schema';


-- Migración: 20261029000000_inyectado_ciclos.sql

create function egeo_privado.validar_ciclos_tarea(p_tarea uuid,p_pedido uuid) returns void
language plpgsql set search_path='' as $$
declare invalido record; minimo numeric; maximo numeric;
begin
 select pa.codigo,pa.unidades_ciclo,(r.piezas_ok::bigint+r.piezas_scrap) total into invalido
 from public.pedido_articulos pa join public.tarea_resultados r on r.articulo_id=pa.articulo_id and r.tarea_id=p_tarea
 where pa.pedido_id=p_pedido and mod(r.piezas_ok::bigint+r.piezas_scrap,pa.unidades_ciclo)<>0 order by pa.codigo limit 1;
 if found then raise exception '%: OK + scrap (%) debe ser múltiplo de %',invalido.codigo,invalido.total,invalido.unidades_ciclo using errcode='22023'; end if;
 select min((r.piezas_ok::numeric+r.piezas_scrap)/pa.unidades_ciclo),max((r.piezas_ok::numeric+r.piezas_scrap)/pa.unidades_ciclo)
 into minimo,maximo from public.pedido_articulos pa join public.tarea_resultados r on r.articulo_id=pa.articulo_id and r.tarea_id=p_tarea where pa.pedido_id=p_pedido;
 if minimo is distinct from maximo then raise exception 'Todos los artículos deben corresponder a la misma cantidad de ciclos' using errcode='22023'; end if;
end $$;
revoke all on function egeo_privado.validar_ciclos_tarea(uuid,uuid) from public,anon,authenticated;

-- Invocador: respeta la visibilidad de las tareas y sus resultados.
-- Los datos históricos incompatibles conservan sus cantidades y devuelven NULL.
create function egeo_privado.ciclos_tarea(p_tarea uuid) returns numeric
language sql stable set search_path='' as $$
 select case when count(r.tarea_id)=count(pa.articulo_id)
  and bool_and(mod(r.piezas_ok::bigint+r.piezas_scrap,pa.unidades_ciclo)=0)
  and min((r.piezas_ok::numeric+r.piezas_scrap)/pa.unidades_ciclo)=max((r.piezas_ok::numeric+r.piezas_scrap)/pa.unidades_ciclo)
  then max((r.piezas_ok::numeric+r.piezas_scrap)/pa.unidades_ciclo) end
 from public.tareas t join public.pedido_articulos pa on pa.pedido_id=t.pedido_id
 left join public.tarea_resultados r on r.tarea_id=t.id and r.articulo_id=pa.articulo_id where t.id=p_tarea;
$$;
revoke all on function egeo_privado.ciclos_tarea(uuid) from public,anon;
grant execute on function egeo_privado.ciclos_tarea(uuid) to authenticated;
create or replace function egeo_privado.validar_proceso_tarea() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.pedidos%rowtype;
begin
 select * into p from public.pedidos where id=new.pedido_id;
 if p.proceso is not null and p.proceso<>new.actividad then raise exception 'La tarea debe usar el proceso de la orden'; end if;
 if p.molde_id is not null and new.confirmada then
  if (select count(*) from public.tarea_resultados where tarea_id=new.id)<>(select count(*) from public.pedido_articulos where pedido_id=p.id)
    or exists(select 1 from public.tarea_resultados r where r.tarea_id=new.id and not exists(select 1 from public.pedido_articulos pa where pa.pedido_id=p.id and pa.articulo_id=r.articulo_id))
    or new.piezas_ok<>(select coalesce(sum(piezas_ok),0) from public.tarea_resultados where tarea_id=new.id)
    or new.piezas_scrap<>(select coalesce(sum(piezas_scrap),0) from public.tarea_resultados where tarea_id=new.id) then
   raise exception 'Registrá las cantidades por cada artículo del molde';
  end if;
  if tg_op='INSERT' or not old.confirmada or (new.piezas_ok,new.piezas_scrap) is distinct from (old.piezas_ok,old.piezas_scrap) then
   perform egeo_privado.validar_ciclos_tarea(new.id,p.id);
  end if;
 end if;
 return new;
end $$;
create or replace view public.v_tareas with (security_invoker = on) as
select t.id, t.pedido_id, p.codigo as pedido_codigo, p.articulo_id,
       coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre, t.actividad,
       coalesce(pe.nombre, '—') as operario_nombre, t.operario_id,
       t.inicio, t.fin, t.piezas_ok, t.piezas_scrap, t.creado, t.confirmada,
       case when t.fin is null then null else
         greatest(0, floor(extract(epoch from (t.fin - t.inicio))
                          - pausas.segundos))::int end as real_seg,
       (case when p.molde_id is not null then (p.configuracion->>'segundos_ciclo')::numeric * egeo_privado.ciclos_tarea(t.id) when p.proceso is not null then t.piezas_ok*(p.configuracion->>'segundos_unidad')::numeric else t.piezas_ok * (case t.actividad
          when 'inyectado' then a.std_inyectado
          when 'rebabado' then a.std_rebabado
          when 'armado' then a.std_armado
          when 'embolsado' then a.std_embolsado end) end)::numeric as std_seg,
       t.observaciones, t.revision,
       greatest(0, floor(extract(epoch from
         (coalesce(t.fin, statement_timestamp()) - t.inicio))))::int as total_seg,
       greatest(0, floor(pausas.segundos))::int as pausa_seg,
       abierta.id as pausa_id, abierta.inicio as pausa_inicio,
       abierta.motivo as pausa_motivo,
       statement_timestamp() as servidor_ahora, p.molde_id, p.proceso, coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('codigo',pa.codigo,'nombre',pa.nombre,'unidades_ciclo',pa.unidades_ciclo) order by pa.codigo) from public.tarea_resultados r join public.pedido_articulos pa on pa.pedido_id=p.id and pa.articulo_id=r.articulo_id where r.tarea_id=t.id),'[]'::jsonb) as resultados, egeo_privado.ciclos_tarea(t.id) as ciclos, (p.configuracion->>'segundos_ciclo')::numeric as segundos_ciclo
from public.tareas t
join public.pedidos p on p.id = t.pedido_id
left join public.articulos a on a.id = p.articulo_id
left join public.perfiles pe on pe.id = t.operario_id
left join lateral (
  select coalesce(sum(extract(epoch from
    (coalesce(x.fin, t.fin, statement_timestamp()) - x.inicio))), 0) as segundos
  from public.tarea_pausas x where x.tarea_id = t.id
) pausas on true
left join public.tarea_pausas abierta
  on abierta.tarea_id = t.id and abierta.fin is null;
create or replace function public.admin_editar_tarea_molde(p_tarea uuid,p_revision integer,p_inicio timestamptz,p_fin timestamptz,p_resultados jsonb,p_observaciones text,p_motivo text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.tareas%rowtype; antes jsonb; resultado jsonb; x jsonb; u public.perfiles%rowtype;
begin
 u:=egeo_privado.exigir_admin(p_motivo);
 select * into t from public.tareas where id=p_tarea for update;
 if not found or not t.confirmada or t.revision is distinct from p_revision then raise exception 'La tarea cambió o no está confirmada'; end if;
 if not exists(select 1 from public.pedidos where id=t.pedido_id and molde_id is not null) then raise exception 'La tarea no corresponde a molde'; end if;
 select jsonb_agg(to_jsonb(r)) into antes from public.tarea_resultados r where tarea_id=t.id;
 delete from public.tarea_resultados where tarea_id=t.id;
 for x in select * from jsonb_array_elements(p_resultados) loop
  insert into public.tarea_resultados values(t.id,(x->>'articulo_id')::uuid,(x->>'piezas_ok')::integer,(x->>'piezas_scrap')::integer);
 end loop;
 perform egeo_privado.validar_ciclos_tarea(t.id,t.pedido_id);
 resultado:=public.admin_editar_tarea(t.id,p_revision,p_inicio,p_fin,
  (select sum(piezas_ok)::integer from public.tarea_resultados where tarea_id=t.id),
  (select sum(piezas_scrap)::integer from public.tarea_resultados where tarea_id=t.id),p_observaciones,p_motivo);
 insert into public.tarea_auditoria(tarea_id,accion,antes,despues,motivo,usuario_id,usuario_nombre)
 values(t.id,'editar_tarea',jsonb_build_object('resultados',antes),jsonb_build_object('resultados',p_resultados),p_motivo,u.id,u.nombre);
 return resultado;
end $$;
notify pgrst,'reload schema';


create table if not exists egeo_privado.despliegues (
 version text primary key, aplicado_en timestamptz not null default now()
);
revoke all on egeo_privado.despliegues from public,anon,authenticated;
insert into egeo_privado.despliegues(version) values ('20261029_qa_produccion');
notify pgrst, 'reload schema';
commit;
