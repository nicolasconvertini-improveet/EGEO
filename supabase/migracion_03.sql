-- =====================================================================
--  Migración 03 — categoría de artículo
--  Agrega la columna "categoria" (el "Tipo" del listado) y la expone
--  en las vistas para poder filtrar por ella.
--  Ejecutar en: Supabase → SQL Editor → New query → Run. Idempotente.
-- =====================================================================

alter table public.articulos add column if not exists categoria text;

create index if not exists idx_articulos_categoria on public.articulos(categoria);