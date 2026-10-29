begin;
grant insert(proceso,molde_id) on public.pedidos to authenticated;
-- Todas las vistas nuevas siguen RLS; las funciones de aplicación verifican sesión.
revoke all on public.v_pedidos,public.v_tareas from public,anon;
grant select on public.v_pedidos,public.v_tareas to authenticated;
commit;
