-- Comprobación sin modificaciones. Un error indica que hay que revisar el esquema.
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

select current_database(), 'Esquema inicial compatible; verificar también historial 01–19 y respaldo' as resultado;
