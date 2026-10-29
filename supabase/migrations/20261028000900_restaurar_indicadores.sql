-- Recuperar el contrato de resumen, filtros y comparación original junto a las tablas nuevas.
begin;
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
commit;
