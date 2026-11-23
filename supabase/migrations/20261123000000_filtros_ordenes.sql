-- Fecha de la última finalización efectiva; sin inferirla del fin de una tarea.
begin;
set local lock_timeout='10s';
create function egeo_privado.fecha_finalizacion_pedido(p_pedido uuid) returns timestamptz
language plpgsql stable security definer set search_path='' as $$
begin
 perform public.validar_sesion();
 return (
  select max(h.creado) from public.pedido_estado_historial h
  join public.pedidos p on p.id=h.pedido_id
  where p.id=p_pedido and p.estado in ('finalizado','finalizado_pendientes')
   and h.estado_nuevo in ('finalizado','finalizado_pendientes')
   and h.estado_anterior not in ('finalizado','finalizado_pendientes')
   and h.origen <> 'migracion_09'
 );
end $$;
revoke all on function egeo_privado.fecha_finalizacion_pedido(uuid) from public,anon;
grant execute on function egeo_privado.fecha_finalizacion_pedido(uuid) to authenticated;
create or replace view public.v_pedidos with(security_invoker=on) as
select p.id,p.codigo,p.articulo_id,
 coalesce(p.configuracion->>'nombre',a.nombre,'Molde '||(p.configuracion->>'codigo')) as articulo_nombre,
 coalesce(p.configuracion->>'codigo',a.codigo) as articulo_codigo,
 p.cantidad,p.estado,p.creado,av.avance as ok_acum,av.bruto as ok_bruto,av.etapas_req,av.etapas_completas,
 egeo_privado.scrap_pedido(p.id) as scrap_acum,p.estado_revision,p.proceso,p.molde_id,p.configuracion,
 egeo_privado.articulos_pedido(p.id) articulos,p.maquina_id,p.material_id,p.requiere_cierre_molde,egeo_privado.control_molde(p.id) control_molde,
 egeo_privado.fecha_finalizacion_pedido(p.id) finalizado_en
from public.pedidos p left join public.articulos a on a.id=p.articulo_id
left join lateral public.avance_pedido(p.id) av on true;
notify pgrst,'reload schema';
commit;
