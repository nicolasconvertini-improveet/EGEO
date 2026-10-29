# Actualizar Supabase real desde QA

Proyecto esperado: **gplitedrfmlakjghfeud** (`https://gplitedrfmlakjghfeud.supabase.co`). Verificar el proyecto abierto antes de ejecutar SQL. Esta preparación no ejecuta cambios remotos ni publica la aplicación.

## 1. Respaldar y comprobar el punto de partida

Guardar un respaldo recuperable de la base real, incluyendo los datos de aplicación y Auth. Revisar la disponibilidad de [backups de Supabase](https://supabase.com/docs/guides/platform/backups) para el plan contratado y comprobar cómo recuperarlo. Un archivo de esquema sin datos no es un respaldo completo.

Coordinar una ventana sin escrituras de producción: la actualización modifica tablas, funciones y vistas. Conservar la versión anterior del frontend para poder volver a publicarla si fuera necesario.

Esta entrega supone que la base existente ya tiene las migraciones históricas **01 a 19**, correspondientes a `schema.sql` y los archivos históricos de `supabase/`. Comprobar ese historial con quien administró la base: el chequeo automático comprueba objetos esenciales, pero no demuestra equivalencia completa de un esquema modificado manualmente.

En SQL Editor del proyecto real, ejecutar primero `supabase/releases/00_verificar_base_real.sql`. Es una comprobación sin escrituras. Si falta un objeto o detecta tablas QA existentes, detenerse y revisar cuáles migraciones faltan. No forzar el paquete borrando tablas o datos.

## 2. Aplicar las 12 migraciones nuevas en una sola operación

Abrir una consulta nueva en **SQL Editor** y pegar **todo** `supabase/releases/20261029_actualizacion_produccion.sql`. Ejecutar con el usuario administrativo de la base. No dividirlo en fragmentos. El paquete incluye desde `20261028000100_procesos_moldes.sql` hasta `20261029000000_inyectado_ciclos.sql`.

El archivo usa una transacción única. Si falla, ninguna parte del paquete debe confirmarse; ejecutar `ROLLBACK;` si la sesión queda con una transacción abortada y revisar el error antes de reintentar. El límite de espera de bloqueos es 10 segundos: ante actividad concurrente puede ser necesario reintentar en la ventana acordada.

**No ejecutar** el baseline `20261028000000_baseline.sql`, `schema.sql`, los scripts históricos, `m_articulos.sql`, semillas ni `db reset` sobre esta base existente. El paquete incremental no agrega artículos de ejemplo, no crea usuarios y no limpia registros reales. Conserva órdenes y registros anteriores; las órdenes antiguas siguen funcionando como históricas multietapa.

Si alguna migración QA ya fue aplicada, usar el historial para determinar las restantes y aplicarlas individualmente en orden, con revisión previa. El paquete completo rechaza una segunda aplicación.

El SQL puede regenerarse con `npm run release:sql`; `npm run release:check` comprueba que coincide con los archivos versionados. Estos comandos solo preparan archivos, no se conectan a Supabase.

## 3. Configurar y publicar el frontend

En la máquina de desarrollo, `.env` debe contener:

```dotenv
VITE_SUPABASE_URL=https://gplitedrfmlakjghfeud.supabase.co
VITE_SUPABASE_ANON_KEY=CLAVE_PUBLICA_DEL_PROYECTO_REAL
SUPABASE_URL=https://gplitedrfmlakjghfeud.supabase.co
SUPABASE_SERVICE_ROLE_KEY=CLAVE_SERVICE_ROLE_DEL_PROYECTO_REAL
```

Obtener las claves desde la configuración API del proyecto. La clave pública debe ser publicable/anon; **nunca** poner una clave service_role/secret en variables `VITE_`, código, Git ni mensajes. La clave de servicio permite a las funciones administrativas crear usuarios y cambiar contraseñas; el inicio de sesión usa la clave pública.

Los archivos con claves se ignoran en Git. `.env.docker.local` solo se carga mediante `npm run dev:docker`; quitar cualquier `.env.local` antiguo que sobrescriba la configuración real. Revisar también las variables del sistema y de Netlify: tienen prioridad sobre los archivos.

Ejecutar `npm run config:check -- --require-server`, `npm run build` y luego `npm run dev`. No es necesario ejecutar seeds para ingresar: usar una cuenta que exista en Authentication del proyecto real, con su perfil activo. Las cuentas Docker no existen en el proyecto real. No cambiar contraseñas existentes para migrar.

En **Netlify**, configurar las mismas cuatro variables para el contexto que se va a publicar. Las `VITE_` se usan durante build; `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` deben estar disponibles en Functions. Elegir deliberadamente QA para la publicación/prueba; este procedimiento no modifica ni fusiona main. Volver a construir después de cambiar variables VITE_.

En Supabase Authentication, revisar Site URL y las redirect URLs de la aplicación publicada y del desarrollo autorizado.

### Publicar la rama QA en Netlify

El proyecto usa **npm** y `package-lock.json`. No agregar un `pnpm-lock.yaml`: Netlify lo detecta y cambia el instalador a pnpm antes de ejecutar el build. Ver [selección de dependencias en Netlify](https://docs.netlify.com/build/configure-builds/manage-dependencies/).

Después de aplicar el SQL y configurar las variables del contexto correspondiente:

1. Subir los commits de QA desde el repositorio: `git push origin QA`.
2. En Netlify, revisar **Project configuration → Developer settings → Continuous deployment → Branches and deploy contexts**. Para una URL propia de QA, habilitar Branch deploys y agregar la rama `QA` respetando mayúsculas. Esto permite conservar main como rama de producción.
3. Mantener Build command `npm run build`, Publish directory `dist` y Functions directory `netlify/functions` (ya definidos en `netlify.toml`). La base del proyecto es la raíz del repositorio.
4. En **Deploys**, abrir el despliegue de QA y seleccionar **Retry without cache** con el último commit de esa rama. El registro de instalación debe indicar npm. No reintentar un commit anterior que conserve el lockfile de pnpm.
5. Cuando figure Published/Ready, abrir la URL del deploy. La URL habitual de una rama QA es `qa--NOMBRE-DEL-SITIO.netlify.app`; usar el enlace que muestre Netlify.

Si se quiere que QA pase a servir el dominio principal, cambiar deliberadamente la **Production branch** a `QA` en la misma configuración y generar el despliegue. Esto cambia qué versión publica Netlify, sin fusionar ni modificar main.

Referencias: [branch deploys](https://docs.netlify.com/deploy/deploy-types/branch-deploys/) y [reintentos de despliegue](https://docs.netlify.com/deploy/manage-deploys/manage-deploys-overview/).

## 4. Verificar antes de habilitar el uso

Consultar en SQL Editor:

```sql
select * from egeo_privado.despliegues
where version = '20261029_qa_produccion';
select to_regclass('public.moldes'), to_regclass('public.solicitudes_trabajo');
```

Ingresar con una cuenta real y comprobar que artículos, usuarios y órdenes previas siguen presentes. Verificar Planta, órdenes por proceso, registro de inyectado con ciclos enteros e iguales por artículo, productividad, avance en unidades/gramos, asignación de trabajos por rol e indicadores. No introducir registros ficticios en producción como parte de esta verificación.

Si el paquete no llegó a confirmar, corregir el error y repetir después del rollback. Si ya confirmó y se cargaron datos nuevos, no intentar revertir borrando tablas: requiere una recuperación planificada del respaldo y considerar las nuevas escrituras.

## Historial CLI

La ruta recomendada arriba es SQL Editor para una base histórica administrada con scripts. No ejecutar después `supabase db push` sin reconciliar el historial remoto: podría intentar reproducir el baseline o migraciones ya aplicadas. Un futuro uso del CLI requiere verificar equivalencia del esquema y registrar las versiones aplicadas mediante el procedimiento oficial de [migraciones](https://supabase.com/docs/guides/deployment/database-migrations) y [migration repair](https://supabase.com/docs/reference/cli/supabase-migration-repair). Repair cambia el historial; no ejecuta ni valida el SQL. El paquete deja además su marca en `egeo_privado.despliegues`, sin inventar un historial CLI remoto.
