# Indicadores: implementación y revisión técnica

## Alcance

Revisión de los cambios del módulo Indicadores realizados el 5 de octubre de 2026.
Conserva navegación, permisos y reglas de producción de las pantallas anteriores.
No modifica autenticación, contraseñas, órdenes ni auditoría de estados.
No se publicó la aplicación ni se ejecutó SQL en Supabase.

## Organización

- `src/pages/Indicadores.jsx`: estado de filtros, carga cancelable y composición de la pantalla.
- `src/lib/indicadoresApi.js`: acceso a la RPC; no usa claves privilegiadas.
- `src/lib/indicadoresContrato.js`: verifica fechas, días completos, duplicados y cantidades antes de mostrar resultados.
- `src/lib/indicadores.js`: cálculos y selección de artículos, independientes de React.
- `src/lib/indicadoresFormato.js`: fechas, validación de períodos y formatos compartidos.
- `src/components/ColumnasApiladas.jsx`: gráfico reutilizable con tabla accesible de valores.
- `src/components/SelectorArticulosIndicadores.jsx`: selección temporal, cancelación, foco y diálogo nativo.
- `src/indicadores.css`: estilos limitados al módulo; reutiliza colores y botones existentes.

El módulo se carga al abrir Indicadores. App revalida el perfil, pero evita las cuatro
consultas compartidas de artículos/órdenes/tareas/contador que esta pantalla no utiliza.
El resto de las pantallas conserva su carga original.

## Permisos y consistencia

La interfaz solo permite administradores. La función `indicadores_egeo_v2` valida
sesión activa y rol en la base, incluso si se llama sin usar la interfaz.
La migración 12 revoca el acceso a la función anterior para evitar eludir el permiso.
Ninguna comprobación de React reemplaza estos controles de la base.

Los filtros se aplican al pulsar Consultar. Abrir/cerrar el modal no consulta la base.
Cancelar/Escape descarta la selección temporal; Aplicar selección la pasa al formulario.
`null` significa todos los artículos; `[]` significa ninguno. Buscar o filtrar categoría
no elimina artículos ya seleccionados. Mantenimiento sigue siendo global.

Las consultas se cancelan al abandonar la pantalla y sus respuestas tardías se ignoran.
Un fallo de carga no conserva resultados antiguos como si fueran actuales.
Una fecha inválida en el formulario no borra el último resultado válido.

## Rendimiento

- Formatos de números reutilizados, no creados por cada celda.
- Catálogo normalizado una vez para buscar sin acentos.
- Lista del selector en bloques de 100; detalle en páginas de 20.
- Series, totales y agrupaciones memorizados.
- Gráficos separados y memorizados; no se recalculan por escribir en el buscador.
- Estilos obsoletos del desplegable y gráficos anteriores eliminados.
- Gráfico de un solo día adaptado a un ancho móvil; series largas permiten desplazamiento.
- Sin dependencias nuevas de producción.

No se ha medido el rendimiento contra la base real. Las verificaciones locales no
sustituyen revisar el plan de consultas con volúmenes representativos de producción.

## Migración 13 (pendiente de aplicar en Supabase)

Archivo: `supabase/migracion_13_indicadores_rendimiento.sql`.
Aplicar después de la 12, primero en una base de prueba.

Mantiene la firma, el JSON y los permisos de `indicadores_egeo_v2`; por eso el frontend
también funciona con la migración 12 mientras se valida esta optimización.

Cambios:
- Restringe las tareas a las que se superponen con el período, incluyendo las que cruzan medianoche.
- Agrega mantenimientos una vez por fecha, en vez de repetir tres consultas por cada día.
- El límite de 20.000 tareas respeta artículos y proceso seleccionados y detiene el conteo en 20.001.
- Agrega tres índices para tareas confirmadas, fecha de mantenimiento y primer cierre completo.

La migración es transaccional y puede repetirse. No modifica datos ni reescribe las
migraciones 11/12 ya aplicadas. Los índices se crean de forma normal dentro de la
transacción: planificar su aplicación según el tamaño y la actividad de la base.

## Reglas que se conservan

- Fechas de negocio: America/Argentina/Buenos_Aires, sin mostrar aquella leyenda en pantalla.
- Hasta 93 días inclusivos; cantidades al día de fin de la tarea confirmada.
- Horas distribuidas por el intervalo diario real; hasta dos decimales en tiempos.
- Producción gráfica: buenas y scrap del último proceso con estándar positivo, no suma de etapas.
- Tiempo estándar actual; no se presenta como presupuesto histórico original.
- Los tiempos de mantenimiento, pausas y producción pueden superponerse: no equivalen a asistencia.
- Primer cierre completo registrado por orden; sin inventar fechas de órdenes anteriores a la auditoría.
- No aplica cuando no existe denominador/estándar válido; promedio de eficiencia ponderado por tiempo.
- Las seis tarjetas y la ayuda se pliegan juntas.

## Pruebas reproducibles

Sin herramientas adicionales:

```powershell
npm run test:indicadores
npm run build
```

Para ejecutar además PostgreSQL local y navegador, instalar herramientas aisladas
(no cambia package.json ni las dependencias productivas):

```powershell
npm install --prefix .validacion @electric-sql/pglite playwright
$env:EGEO_PGLITE_MODULE = (Resolve-Path .validacion/node_modules/@electric-sql/pglite/dist/index.js).Path
$env:EGEO_PLAYWRIGHT_MODULE = (Resolve-Path .validacion/node_modules/playwright/index.mjs).Path
node tests/indicadores-sql.mjs
node tests/indicadores-ui.mjs
```

La prueba UI usa Edge instalado en Windows con un perfil temporal y sin abrir una
ventana. Puede configurarse otro navegador Chromium con `EGEO_BROWSER_PATH`.
Las peticiones de red del navegador de prueba se bloquean: no accede a Supabase.
Los datos de interfaz son ficticios. Capturas: `test-results/` (ignorado por Git).

SQL usa una base PGlite en memoria y un esquema representativo. Simula sesión/rol;
no verifica firmas JWT ni configuración remota de Supabase. Prueba migraciones
11, 12 y 13, repetición, roles, sesión inactiva, permisos de la función antigua,
días sin actividad, medianoche, duplicación de cierres y límites con más de 20.000 tareas.

UI prueba móvil y horizontal, selección entre categorías, Cancelar/Escape, retorno
y retención del foco, pie visible, paginación, tarjetas alineadas, ayuda plegable,
decimales, error/reintento y ausencia de consultas para supervisor.

Antes de evaluar producción: aplicar/confirmar permisos de la 12, validar la 13
y comprobar los indicadores con registros conocidos en la base de prueba.
