-- Nuevas órdenes por proceso; legado sin reinterpretación de cantidades.
begin;
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
commit;
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
