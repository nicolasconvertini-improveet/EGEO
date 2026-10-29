# Auditoría y corrección de regresiones del frontend de QA

Referencia original: rama `main`, commit `c2fece519f0f6adab60946b3c37747b7a1476e03`.
La comparación se realizó leyendo archivos de esa rama; no se hizo checkout, commit ni cambio alguno sobre main.

## Regresiones encontradas y corregidas

- **Nueva orden:** la reescritura había sustituido el selector original por un desplegable simple. Se recuperó el selector de main: búsqueda por palabras sin distinguir tildes/mayúsculas, prioridad de código exacto, categorías, resultados de 20 en 20, ficha de selección con estándares y «Cambiar artículo». Se conserva la selección de un proceso y, en inyectado, de un molde con todos sus artículos. El buscador de moldes también permite buscar por sus artículos y máquina.
- **Indicadores:** además de reemplazar los gráficos, se habían eliminado filtros plegables, atajos Hoy/Esta semana/Este mes, reintento de consulta, tarjetas de resumen, ayudas, comparación agrupada de tiempos y paginación. Se restauraron desde main. Solo los gráficos Producción por día y Tiempos por día quedan sustituidos por las tablas solicitadas; la opción diaria asociada a esos gráficos no vuelve a mostrarse.
- **Alcance de los gráficos:** en el código de main hay dos instancias de gráficos en Indicadores, ambas de `ColumnasApiladas`. Las visualizaciones adicionales de esa pantalla son tarjetas de resumen y tablas de comparación; también se recuperaron. Los gráficos de productividad, pausas y evolución del tablero original se conservan.
- **Cabecera:** se retiraron los cambios generales de espaciado de la cabecera introducidos en los ajustes móviles, para volver al diseño original.
- **Filtro de usuario en mantenimiento de Indicadores:** se recuperó el alcance original, que incluye toda la planta y no depende del usuario, artículo o proceso seleccionados. Las tareas de producción sí respetan esos filtros.

## Correcciones explícitas de esta revisión

- Planta: Moldes, Máquinas, Equipos y Nuevo registro comparten una fila; se distribuyen en cuatro columnas iguales y caben en el ancho disponible, sin desplazamiento horizontal.
- Artículos: el selector de categorías siempre está visible. «Sin categoría» permite filtrar registros que no tengan una categoría cargada.
- Trabajos: se reemplazó la opción ambigua «pendientes» por «Sin resolver», que es un filtro conjunto. Los estados reales aparecen una sola vez: Pendiente de asignación, Asignada, En curso y Resuelta.
- Tablero: seis tarjetas, una por cada combinación de tipo (mantenimiento/molienda) y estado accionable (pendiente de asignación, asignada o en curso). Las resueltas se consultan en Trabajos y no aparecen en el tablero. Muestran únicamente cantidades; cada clic navega a Trabajos prefiltrado por esos dos valores.

## Otras áreas revisadas

- Login, Usuarios, Exportar, SearchBox, EstadoPedido, ColumnasApiladas, lógica original de agregaciones y estilos de Indicadores: sin diferencias respecto de main.
- Tablero: se conserva el contenido original y se agrega exclusivamente el bloque de tarjetas de trabajos. Otras diferencias de código son formato.
- Registrar, Tareas y Edición de tarea: los cambios funcionales corresponden a proceso único, resultados por artículo y estándar congelado de órdenes nuevas. Se conservan pausas, cronómetro, confirmación, observaciones y edición de pausas.
- Órdenes: se conserva la consulta y edición de cantidades y estados, adaptando unidades/ciclos y avance según el modelo solicitado. La búsqueda original de artículos vuelve mediante un componente separado.
- Navegación: conserva las pestañas y la disposición móvil/tablet/escritorio. Planta es la sección nueva; Trabajos reúne mantenimiento y molienda. El menú mantiene visible la sección activa.
- Guía: se actualizaron las explicaciones que dependían de los nuevos procesos. No se cambió el comportamiento de las pantallas a partir de la guía.

## Coherencia de datos

La consulta de Indicadores ahora devuelve también los datos necesarios para el resumen y comparación originales, incluyendo tareas de moldes sin duplicar su duración. Las cantidades de las tablas se desglosan por artículo; el detalle de tiempo de una tarea de molde mantiene una fila por tarea, identificada por el molde, sin inventar un reparto de horas entre piezas. Se conserva el límite de 20.000 tareas del contrato original.

## Verificación

- Compilación de Vite.
- Pruebas existentes de indicadores.
- Pruebas de regresión de componentes: barra de Planta, categorías visibles, selector original de artículos, tarjetas sin detalle y destino/filtros de sus clics.
- Integración contra Docker local: consulta real de indicadores, validación del contrato original y coincidencia de horas entre resumen y tabla.
- La herramienta de uso de computadora pudo leer Chrome, pero no activarlo para operar la pestaña local («failed to activate captured window»). La revisión automatizada no constituye una validación visual completa; el diseño se contrastó con las capturas aportadas y las reglas originales de main.
