# EGEO — Productividad de planta

Aplicación React + Supabase + Netlify para producción, órdenes por proceso, moldes, máquinas/equipos, mantenimiento, molienda e indicadores. Roles: operario, supervisor y administrador.

## Supabase real (configuración predeterminada)

Antes de usar esta versión, aplicar las migraciones según [la guía de despliegue](docs/despliegue-supabase.md). La rama main permanece intacta.

1. Instalar dependencias con `npm ci`.
2. Si no existe `.env`, copiar `.env.example` a `.env`. Completar las claves del proyecto real. Nunca sobrescribir un archivo existente sin revisar sus valores.
3. Ejecutar `npm run config:check` y `npm run dev`.

La aplicación abre en http://127.0.0.1:5173. El mismo comando inicia las funciones administrativas en el puerto 5174. La clave de servicio se configura solo en el servidor: nunca en una variable VITE_. Las cuentas y contraseñas son las de Supabase real; no se crean usuarios ni datos de ejemplo al arrancar.

## Base Docker opcional

Ver [desarrollo local](docs/desarrollo-local-docker.md). Se usa exclusivamente con `npm run dev:docker` y `.env.docker.local`; no reemplaza la conexión habitual. Las pruebas de integración solo permiten esta base local.

## Migraciones y publicación

`supabase/migrations` conserva el historial versionado. El baseline es para bases vacías. Para actualizar la base real existente usar el paquete incremental de `supabase/releases`, siguiendo [las instrucciones](docs/despliegue-supabase.md).

Netlify usa `netlify.toml`: build `npm run build`, publicación `dist` y funciones en `netlify/functions`. Configurar las variables del proyecto real antes de publicar; aplicar primero el SQL.

## Reglas de producción

Las órdenes nuevas corresponden a un solo proceso. Inyectado usa un molde y todos sus artículos; los otros procesos usan un artículo. La orden conserva una copia de su configuración.

Inyectado calcula productividad con ciclos ejecutados × segundos estándar por ciclo ÷ segundos operativos netos × 100. OK + scrap debe representar ciclos enteros e iguales para todos los artículos. Solo OK reduce el pendiente; material por ciclo siempre se expresa en gramos. Las órdenes históricas mantienen su interpretación anterior.

Mantenimiento y molienda comparten solicitud, asignación, inicio y resolución; molienda permite observaciones. El operario ve sus asignaciones. Los permisos también se controlan en Supabase mediante RLS y funciones.

## Verificación

`npm run build`, `npm run test:indicadores`, `npm run test:frontend` y `npm run test:inyectado` no modifican la base real. `npm run test:local` requiere Docker y genera fixtures identificados con prefijo test-.
