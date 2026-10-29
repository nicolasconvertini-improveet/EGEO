begin;
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
commit;
