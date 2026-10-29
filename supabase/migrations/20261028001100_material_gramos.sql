-- Fijar gramos en el catálogo; las configuraciones históricas de órdenes se conservan.
begin;
alter table public.moldes alter column unidad_material set default 'g';
alter table public.moldes add constraint moldes_unidad_gramos check(unidad_material='g');
create or replace function public.guardar_molde(p_id uuid,p_datos jsonb,p_articulos jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare mid uuid := coalesce(p_id,gen_random_uuid()); x jsonb;
begin
 perform public.validar_sesion();
 if public.rol_actual()<>'admin' then raise exception 'Solo administrador' using errcode='42501'; end if;
 if p_datos ? 'unidad_material' and coalesce(p_datos->>'unidad_material','') <> 'g' then
  raise exception 'El material por ciclo se expresa siempre en gramos (g)';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(mid::text,0));
 perform 1 from public.maquinas where id=(p_datos->>'maquina_id')::uuid and (activo or not (p_datos->>'activo')::boolean) for share;
 if not found then raise exception 'Seleccioná una máquina activa'; end if;
 if jsonb_typeof(p_articulos)<>'array' or jsonb_array_length(p_articulos)=0 then raise exception 'Agregá al menos un artículo'; end if;
 insert into public.moldes(id,codigo,maquina_id,material,material_ciclo,unidad_material,segundos_ciclo,activo)
 values(mid,btrim(p_datos->>'codigo'),(p_datos->>'maquina_id')::uuid,btrim(p_datos->>'material'),
 (p_datos->>'material_ciclo')::numeric,'g',(p_datos->>'segundos_ciclo')::numeric,(p_datos->>'activo')::boolean)
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
notify pgrst,'reload schema';
commit;
