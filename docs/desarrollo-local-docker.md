# EGEO QA — Desarrollo local con Docker

Esta rama implementa órdenes de un proceso, moldes con múltiples artículos, maestros de máquinas/equipos, solicitudes de mantenimiento y molienda, y los nuevos indicadores en tablas. El backend local es Supabase (PostgreSQL + Auth + API) ejecutado en Docker; el frontend y las funciones administrativas se ejecutan con Node.

## Arranque

Requisitos: Docker Desktop iniciado con contenedores Linux y Node 24 (versiones usadas para validar). Usar npm y el `package-lock.json` actualizado de esta rama.

Desde `C:\Users\nico_\Documents\GitHub\EGEO`, con la rama `QA` activa:

```powershell
npm ci
npm run db:start
npm run db:configure
npm run db:users
npm run dev:local
```

- Aplicación: http://127.0.0.1:5173
- Supabase Studio: http://127.0.0.1:54323
- Las credenciales de admin, supervisor y operario de prueba se guardan en `.local/usuarios-demo.json`, excluido de Git.
- `db:configure` crea `.env.local` sin modificar `.env`. No sobrescribe una configuración local existente. Para reemplazarla deliberadamente: `node scripts/configure-local.mjs --replace`.
- `db:users` es una operación inicial: no modifica contraseñas si el archivo de credenciales ya existe.
- Para ejecuciones siguientes basta `npm run db:start` y `npm run dev:local`.
- La primera puesta en marcha descarga imágenes y requiere Internet. No se requiere un proyecto Supabase cloud.

El servidor local de funciones escucha en 127.0.0.1:5174 y Vite redirige `/.netlify/functions/*` a ese servidor. Crear usuarios y consultar/cambiar sus credenciales conserva los controles del servidor existente. Ejecutar solo `npm run dev` permite abrir la interfaz, pero no inicia las funciones administrativas.

## Detener y actualizar

```powershell
# En la terminal del frontend: Ctrl+C.
npm run db:stop

# Después de actualizar el código y con Docker iniciado:
npm run db:start
npm run db:migrate
```

Los datos se conservan al detener y reiniciar normalmente. El inicio no ejecuta resets ni elimina volúmenes. No ejecutar `supabase db reset` sobre datos que deban conservarse.

El CLI administra los contenedores, por eso no se introduce un segundo Compose que compita por los puertos. Esta configuración es un entorno local de desarrollo/QA. Para una instalación permanente accesible desde varias computadoras se necesita preparar un despliegue autohospedado y su configuración de red.

## Migraciones y datos existentes

`supabase/migrations/20261028000000_baseline.sql` reproduce `schema.sql` y las 19 migraciones históricas en su orden. Las migraciones posteriores agregan la nueva funcionalidad. `npm run db:baseline:check` verifica que el baseline corresponda al historial original.

Una instalación nueva aplica el historial automáticamente. No ejecutar por separado `schema.sql` ni volver a ejecutar los scripts históricos sobre esta base.

Las órdenes históricas mantienen sus procesos y cantidades originales y se identifican como históricas multietapa. Las nuevas exigen un proceso único. Los mantenimientos anteriores siguen disponibles como trabajos resueltos en el historial; no se transforman en solicitudes pendientes.

Los textos antiguos de molde/máquina en artículos se conservan para consulta. No se convierten automáticamente en moldes: faltan datos obligatorios como consumo de material y segundos por ciclo. Crear las configuraciones completas en Planta. No se inventan relaciones históricas ni se cambia el proceso de órdenes existentes.

Para actualizar una base antigua que ya tiene las migraciones 01–19, aplicar únicamente las migraciones nuevas posteriores al baseline. No aplicar el baseline sobre una base existente ni marcarlo como aplicado sin comprobar antes la equivalencia del esquema. Este entorno fue preparado y probado contra una base local nueva; no se modificó Supabase cloud.

## Uso funcional

### Planta

Con administrador, entrar en **Planta**:

1. Crear máquinas y, si corresponde, equipos.
2. Crear un molde con su código, una máquina, material, cantidad y unidad de material por ciclo, segundos por ciclo y todos los artículos que produce.
3. Indicar unidades por ciclo para cada artículo.
4. Editar o desactivar desde el mismo formulario.

Una máquina con moldes activos no puede desactivarse hasta reasignarlos o desactivarlos. No se borran referencias históricas.

### Órdenes y producción

- Una orden de inyectado selecciona un molde e incluye todos sus artículos. Su cantidad se expresa en **ciclos previstos** y cada objetivo es ciclos × unidades por ciclo.
- La orden se completa cuando todos los artículos alcanzan su objetivo de piezas OK. El avance en ciclos equivalentes es el mínimo de las cantidades OK normalizadas por sus unidades por ciclo.
- Una orden de rebabado, armado o embolsado selecciona un solo artículo y su objetivo en piezas.
- No se puede iniciar una actividad diferente al proceso de la orden.
- La orden guarda una copia de la configuración; editar el molde no altera sus artículos ni estándares históricos.
- Al finalizar una tarea de inyectado, cargar OK y rechazo para cada artículo. La confirmación es atómica y los reintentos con el mismo contenido no duplican resultados.
- La edición administrativa incluye el detalle por artículo y deja auditoría. Las exportaciones de tareas generan una fila por artículo.

El estándar de inyectado utiliza ciclos equivalentes OK = mínimo de OK/unidades por ciclo, multiplicado por segundos por ciclo. Es una regla conservadora ante rechazos desiguales y evita sumar el tiempo completo de ciclo por cada pieza. El avance usa ciclos enteros; la comparación de estándar admite fracciones. Esta decisión y la meta por ciclos deben validarse con el responsable del proceso antes de usar los indicadores para evaluación operativa.

### Mantenimiento y molienda

**Trabajos** reúne pendientes, asignadas, en curso, resueltas y el historial de intervenciones anteriores.

- Administrador y supervisor pueden solicitar y asignar/reasignar.
- Mantenimiento identifica una máquina o equipo y describe la solicitud.
- Molienda no requiere equipo ni detalle obligatorio. Incluye observaciones opcionales al solicitar y al resolver; se conservan en el historial y en el reporte.
- El operario consulta e inicia/resuelve únicamente sus tareas asignadas. La restricción también se aplica en SQL/RPC y a la exportación del historial.
- Al resolver se registran los minutos. En mantenimiento se describe el trabajo realizado; en molienda se pueden agregar observaciones opcionales.
- Las reasignaciones y transiciones quedan auditadas.
- El tablero muestra cantidades por tipo y estado en tarjetas que abren Trabajos con esos filtros, según los roles habilitados.
- El reporte de solicitudes permite filtrar estado, tipo, usuario y equipo, y descargar el listado visible.

### Indicadores

- Producción por artículo: código, descripción, OK y scrap/rechazo.
- Horas por motivo: producción por proceso, pausas por motivo y mantenimiento/molienda, más total de horas.
- Se eliminan ambos gráficos diarios y la opción de valores por día.
- Los filtros de período, artículos, proceso y usuario conservan su presentación original, junto con las tarjetas de resumen y la comparación agrupada de tiempos.
- Al consultar todos los procesos, las cantidades suman operaciones de fabricación: una pieza puede haber pasado por más de un proceso.
- Filtrar un artículo de un molde incluye la duración completa de la tarea una sola vez; no se inventa un reparto de horas entre piezas.
- Mantenimiento y molienda conservan el alcance original de toda la planta por fecha de ejecución/resolución; no dependen del filtro de usuario, artículo o proceso.
- Los tiempos de producción y pausas se recortan al período. Las cantidades corresponden al fin de la tarea confirmada. El total se calcula antes del redondeo visual.

## Respaldos y recuperación de prueba

```powershell
npm run db:backup -- backups/mi-respaldo.dump
npm run db:restore:test -- backups/mi-respaldo.dump egeo_restore_mi_prueba
```

El respaldo incluye los esquemas de aplicación, Auth y el historial de migraciones. El archivo contiene información sensible y queda excluido de Git. Guardarlo en una ubicación protegida.

La restauración crea una base **nueva y aislada** dentro del contenedor. El nombre debe empezar con `egeo_restore_`; si ya existe, el comando falla. No sobrescribe la base activa. El script no restaura privilegios/propietarios y su destino es validar la recuperación de datos con PostgreSQL; para reemplazar el entorno activo hay que planificar además roles, servicios y configuración. Storage está deshabilitado y no se incluyen archivos multimedia externos.

## Validación

```powershell
npm run build
npm run test:indicadores
npm run test:frontend
npm run test:local
npm run db:baseline:check
```

La prueba local exige Docker/Supabase iniciado y genera datos ficticios con prefijo `test-` y usuarios de prueba. No usa ni modifica la base remota.

Comprueba creación de órdenes y moldes, resultados por artículo, reintentos, congelamiento de configuración, avance, edición administrativa, exportación, solicitudes de molienda/mantenimiento, permisos por rol, totales y filtros de indicadores y las funciones locales de usuarios. También recorre el módulo API real del frontend y genera el formulario de edición de molde con renderizado de React para verificar sus campos.

Se probó el inicio desde cero, las migraciones incrementales, el respaldo y una restauración aislada. La revisión visual interactiva quedó pendiente porque Computer Use no pudo verificar la URL de Chrome en Windows; no se presenta el renderizado estático como una validación visual.

## Alcance de entrega

Los cambios quedan en la rama local `QA`. No se ejecutó despliegue, push ni migración sobre Supabase cloud. La interfaz nueva necesita estas migraciones; no publicarla contra el esquema remoto anterior.
