begin;
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
commit;
