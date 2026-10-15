-- Aplicar DESPUÉS de la migración 13. Agrega el filtro por usuario (operario) a indicadores.
-- Cambia la firma: se elimina la versión de 4 parámetros y se crea la de 5.
begin;
drop function if exists public.indicadores_egeo_v2(date,date,uuid[],text);
create index if not exists indicadores_tareas_operario
  on public.tareas (operario_id, fin) where confirmada;
create index if not exists indicadores_tareas_fin_confirmadas
  on public.tareas (fin, pedido_id) where confirmada;
create index if not exists indicadores_mantenimientos_fecha
  on public.mantenimientos (fecha_ejecucion);
create index if not exists indicadores_historial_finalizado
  on public.pedido_estado_historial (pedido_id, creado) where estado_nuevo = 'finalizado';

create or replace function public.indicadores_egeo_v2(
 p_desde date, p_hasta date, p_articulos uuid[] default null, p_proceso text default '',
 p_operario uuid default null
) returns jsonb language plpgsql stable security definer
set search_path = '' set timezone = 'America/Argentina/Buenos_Aires'
as $$
declare resultado jsonb; n bigint;
begin
 if not coalesce(egeo_privado.sesion_activa(), false)
    or coalesce(public.rol_actual(), '') <> 'admin' then
   raise exception 'Se requiere una sesión activa de administrador' using errcode='42501';
 end if;
 if p_desde is null or p_hasta is null or not isfinite(p_desde) or not isfinite(p_hasta)
    or p_hasta < p_desde or p_hasta - p_desde > 92 or p_hasta > current_date
    or coalesce(cardinality(p_articulos),0) > 50000
    or coalesce(p_proceso,'') not in ('','inyectado','rebabado','armado','embolsado') then
   raise exception 'Elegí un período de hasta 93 días, sin fechas futuras, y filtros válidos';
 end if;
 -- Fallar explícitamente antes que entregar detalles recortados.
 select count(*) into n from (
   select 1 from public.tareas t join public.pedidos p on p.id=t.pedido_id
   where t.confirmada and t.fin >= p_desde::timestamptz and t.fin < (p_hasta+1)::timestamptz
     and (p_articulos is null or p.articulo_id = any(p_articulos))
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
   limit 20001
 ) candidatas;
 if n > 20000 then raise exception 'Hay más de 20.000 tareas. Reducí el período para consultar el detalle completo'; end if;
 with
 elegibles as (
   select p.id, p.codigo, p.articulo_id, a.nombre, a.codigo articulo_codigo,
     case when a.std_embolsado > 0 then 'embolsado'
          when a.std_armado > 0 then 'armado'
          when a.std_rebabado > 0 then 'rebabado'
          when a.std_inyectado > 0 then 'inyectado' end ultimo
   from public.pedidos p join public.articulos a on a.id=p.articulo_id
   where p_articulos is null or a.id = any(p_articulos)
 ),
 tareas as (
   select t.*, e.articulo_codigo, e.ultimo,
     case t.actividad when 'inyectado' then a.std_inyectado
       when 'rebabado' then a.std_rebabado when 'armado' then a.std_armado
       when 'embolsado' then a.std_embolsado end estandar
   from public.v_tareas t join elegibles e on e.id=t.pedido_id
   join public.articulos a on a.id=t.articulo_id
   where t.confirmada and t.fin >= p_desde::timestamptz
     and t.inicio < (p_hasta+1)::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
 ),
 detalles as (
   select id,pedido_id,pedido_codigo,articulo_id,articulo_nombre,articulo_codigo,
     actividad,operario_id,operario_nombre,fin::date dia,piezas_ok,piezas_scrap,real_seg,std_seg,
     estandar, (actividad=ultimo) es_ultimo
   from tareas where fin >= p_desde::timestamptz and fin < (p_hasta+1)::timestamptz
 ),
 dias as (select (p_desde+i)::date dia from generate_series(0,p_hasta-p_desde) i),
 -- Horas distribuidas por día real. Solo tareas confirmadas.
 horas as (
   select d.dia, coalesce(sum(greatest(0, extract(epoch from
     (least(t.fin,(d.dia+1)::timestamptz)-greatest(t.inicio,d.dia::timestamptz))))
     - coalesce(x.pausa,0)) filter (where t.id is not null),0) real
   from dias d left join tareas t on t.inicio < (d.dia+1)::timestamptz and t.fin > d.dia::timestamptz
   left join lateral (
     select sum(greatest(0,extract(epoch from
       (least(coalesce(p.fin,t.fin),t.fin,(d.dia+1)::timestamptz)
        -greatest(p.inicio,t.inicio,d.dia::timestamptz))))) pausa
     from public.tarea_pausas p where p.tarea_id=t.id
   ) x on true group by d.dia
 ),
 pausas as (
   select d.dia, count(p.id) filter(where p.inicio >= d.dia::timestamptz
     and p.inicio < (d.dia+1)::timestamptz) cantidad,
     coalesce(sum(extract(epoch from
       (least(coalesce(p.fin,statement_timestamp()),(d.dia+1)::timestamptz)
        -greatest(p.inicio,d.dia::timestamptz)))) filter (where p.id is not null),0) segundos
   from dias d left join (
     public.tarea_pausas p join public.tareas t on t.id=p.tarea_id
     join elegibles e on e.id=t.pedido_id
   ) on p.inicio < least((d.dia+1)::timestamptz,statement_timestamp())
     and coalesce(p.fin,statement_timestamp()) > d.dia::timestamptz
     and (coalesce(p_proceso,'')='' or t.actividad=p_proceso)
     and (p_operario is null or t.operario_id=p_operario)
   group by d.dia
 ),
 cierres as (
   select h.pedido_id, min(h.creado)::date dia
   from public.pedido_estado_historial h join elegibles e on e.id=h.pedido_id
   where h.estado_nuevo='finalizado'
   group by h.pedido_id
 ),
 mantenimiento_diario as (
   select fecha_ejecucion dia, count(*) cantidad, sum(minutos)::numeric*60 segundos,
     coalesce(sum(minutos) filter (where not preventivo),0)::numeric*60 correctivo
   from public.mantenimientos where fecha_ejecucion between p_desde and p_hasta
   group by fecha_ejecucion
 ),
 diario as (
   select d.dia, coalesce(q.tareas,0) tareas,coalesce(q.piezas,0) piezas,
     coalesce(q.ok,0) ok,coalesce(q.scrap,0) scrap,
     greatest(0,h.real) real,pa.cantidad pausas,pa.segundos pausa_seg,
     (select count(*) from cierres c where c.dia=d.dia) ordenes,
     coalesce(m.cantidad,0) mantenimientos,
     coalesce(m.segundos,0) mantenimiento_seg,
     coalesce(m.correctivo,0) correctivo_seg
   from dias d join horas h using(dia) join pausas pa using(dia)
   left join mantenimiento_diario m using(dia)
   left join (
     select dia,count(*) tareas,sum(piezas_ok) ok,sum(piezas_scrap) scrap,
       sum(case when es_ultimo then piezas_ok else 0 end) piezas
     from detalles group by dia
   ) q using(dia)
 )
 select jsonb_build_object(
   'catalogo',(select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'codigo',a.codigo,'nombre',a.nombre,'categoria',nullif(btrim(a.categoria),'')) order by a.nombre,a.id),'[]'::jsonb) from public.articulos a),
   'usuarios',(select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'nombre',u.nombre) order by u.nombre,u.id),'[]'::jsonb)
     from public.perfiles u where exists(select 1 from public.tareas t where t.operario_id=u.id)),
   'operario',p_operario,
   'generado',statement_timestamp(),'desde',p_desde,'hasta',p_hasta,
   'tareas',coalesce((select jsonb_agg(to_jsonb(t) order by dia,id) from detalles t),'[]'::jsonb),
   'dias',coalesce((select jsonb_agg(to_jsonb(d) order by dia) from diario d),'[]'::jsonb),
   'sin_etapas',(select count(*) from detalles where es_ultimo is null),
   'finalizadas_sin_fecha',(select count(*) from public.pedidos p join elegibles e on e.id=p.id
     where p.estado='finalizado' and not exists(select 1 from cierres c where c.pedido_id=p.id))
 ) into resultado;
 return resultado;
end $$;
revoke all on function public.indicadores_egeo_v2(date,date,uuid[],text,uuid) from public,anon;
grant execute on function public.indicadores_egeo_v2(date,date,uuid[],text,uuid) to authenticated;
revoke all on function public.indicadores_egeo(date,date,text,text) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;