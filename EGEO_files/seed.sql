-- Datos de ejemplo (opcional). Ejecutar en el SQL Editor después de schema.sql.
-- Corre como propietario, así que ignora RLS.

insert into public.articulos (codigo, nombre, molde, maquina, bocas, material, activo,
                              std_inyectado, std_rebabado, std_armado, std_embolsado)
values
  ('PCH-C27', 'Percha P.Corta',    '27', 'T120', 8, 'PA7335 Verde', true, 2.4, 6, 0, 3),
  ('PCH-L15', 'Percha Larga',      '15', 'T120', 6, 'PA7335 Negro', true, 3.2, 7, 0, 3),
  ('GCH-04',  'Gancho reforzado',  '4',  'T80',  4, 'PP Blanco',    true, 4.0, 9, 14, 4),
  ('PCH-INF', 'Percha infantil',   '31', 'T80',  8, 'PA Rosa',      false, 2.1, 5, 0, 3)
on conflict (codigo) do nothing;
