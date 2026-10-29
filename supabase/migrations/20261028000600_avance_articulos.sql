begin;
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
commit;
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
