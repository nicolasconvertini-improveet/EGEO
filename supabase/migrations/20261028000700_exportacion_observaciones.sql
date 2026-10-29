begin;
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
commit;
