-- =====================================================================
--  Migración 02 — el pedido se completa sólo cuando TODAS las etapas
--  aplicables alcanzan la cantidad pedida.
--
--  Una pieza se considera terminada cuando pasó por todos los procesos
--  que el artículo requiere (los que tienen tiempo estándar mayor a 0).
--  Por eso el avance del pedido es el de la ETAPA MÁS ATRASADA.
--
--  Ejecutar en: Supabase → SQL Editor → New query → Run
--  Es idempotente y no borra datos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Función de avance
--    Devuelve:
--      avance           = piezas completas (mínimo entre las etapas requeridas)
--      bruto            = suma de piezas de todas las etapas (volumen trabajado)
--      etapas_req       = cuántas etapas requiere el artículo
--      etapas_completas = cuántas ya alcanzaron la cantidad pedida
-- ---------------------------------------------------------------------
create or replace function public.avance_pedido(p_pedido uuid)
returns table(avance int, bruto int, etapas_req int, etapas_completas int)
language plpgsql stable security definer set search_path = public as $$
declare
  v_meta  int;
  v_std   jsonb;
  k       text;
  v_ok    int;
  v_min   int := null;
  v_sum   int := 0;
  v_req   int := 0;
  v_comp  int := 0;
begin
  select p.cantidad,
         jsonb_build_object(
           'inyectado', a.std_inyectado, 'rebabado', a.std_rebabado,
           'armado',    a.std_armado,    'embolsado', a.std_embolsado)
    into v_meta, v_std
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
   where p.id = p_pedido;

  if v_meta is null then
    return;
  end if;

  -- recorre las cuatro etapas y considera sólo las que el artículo usa
  for k in select jsonb_object_keys(v_std) loop
    if coalesce((v_std->>k)::numeric, 0) > 0 then
      select coalesce(sum(piezas_ok), 0)::int into v_ok
        from public.tareas
       where pedido_id = p_pedido and actividad = k and confirmada = true;

      v_req := v_req + 1;
      v_sum := v_sum + v_ok;
      if v_min is null or v_ok < v_min then v_min := v_ok; end if;
      if v_ok >= v_meta then v_comp := v_comp + 1; end if;
    end if;
  end loop;

  -- si el artículo no tiene ningún estándar cargado, se toma el total
  if v_req = 0 then
    select coalesce(sum(piezas_ok), 0)::int into v_sum
      from public.tareas where pedido_id = p_pedido and confirmada = true;
    v_min := v_sum;
  end if;

  avance := coalesce(v_min, 0);
  bruto := v_sum;
  etapas_req := v_req;
  etapas_completas := v_comp;
  return next;
end; $$;

-- ---------------------------------------------------------------------
-- 2) El estado del pedido pasa a depender de la etapa más atrasada
-- ---------------------------------------------------------------------
create or replace function public.recalcular_estado_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_meta   int;
  v_av     int;
  v_bruto  int;
begin
  select cantidad into v_meta from public.pedidos where id = v_pedido;
  select a.avance, a.bruto into v_av, v_bruto from public.avance_pedido(v_pedido) a;

  update public.pedidos
     set estado = case
       when v_meta > 0 and v_av >= v_meta then 'finalizado'
       when coalesce(v_bruto, 0) > 0      then 'en_curso'
       else 'pendiente' end
   where id = v_pedido;
  return null;
end; $$;

-- ---------------------------------------------------------------------
-- 3) La vista de pedidos informa el avance real y el detalle de etapas
-- ---------------------------------------------------------------------
drop view if exists public.v_pedidos;

create or replace view public.v_pedidos with (security_invoker = on) as
  select p.id, p.codigo, p.articulo_id,
         a.nombre as articulo_nombre, a.codigo as articulo_codigo,
         p.cantidad, p.estado, p.creado,
         av.avance           as ok_acum,           -- piezas completas
         av.bruto            as ok_bruto,          -- volumen total trabajado
         av.etapas_req       as etapas_req,
         av.etapas_completas as etapas_completas,
         coalesce((select sum(t.piezas_scrap)::int
                     from public.tareas t
                    where t.pedido_id = p.id and t.confirmada), 0) as scrap_acum
    from public.pedidos p
    join public.articulos a on a.id = p.articulo_id
    left join lateral public.avance_pedido(p.id) av on true;

-- ---------------------------------------------------------------------
-- 4) Recalcular todos los pedidos existentes con el criterio nuevo
--    (corrige los que quedaron marcados como finalizados)
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  v_av int;
  v_bruto int;
begin
  for r in select id, cantidad from public.pedidos loop
    select a.avance, a.bruto into v_av, v_bruto from public.avance_pedido(r.id) a;
    update public.pedidos
       set estado = case
         when r.cantidad > 0 and v_av >= r.cantidad then 'finalizado'
         when coalesce(v_bruto, 0) > 0              then 'en_curso'
         else 'pendiente' end
     where id = r.id;
  end loop;
end $$;
