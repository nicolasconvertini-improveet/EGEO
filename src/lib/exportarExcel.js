const TABLAS = new Set(["tarea_pausas", "tareas", "articulos", "pedidos", "perfiles", "mantenimientos"]);
const MAX_FILAS_DATOS = 1048575; // La primera fila se reserva para encabezados.

function valorExcel(valor, columna) {
  if (valor === null) return null;
  if (typeof valor !== "string") throw new Error("Formato de datos inesperado.");
  if (valor.length > 32767) {
    throw new Error(`La columna ${columna.nombre} contiene un texto que supera el límite de Excel. No se descargó un archivo incompleto.`);
  }
  if (columna.tipo === "bool") return valor === "true";
  if (["int2", "int4", "int8"].includes(columna.tipo)) {
    const numero = Number(valor);
    // Excel sólo garantiza 15 dígitos significativos.
    if (Number.isSafeInteger(numero) && valor.replace(/^-/, "").length <= 15) return numero;
  }
  // Texto explícito: códigos con ceros, UUID, fechas con zona y decimales
  // conservan su representación. Nunca se crean fórmulas desde los datos.
  return { t: "s", v: valor };
}

export function construirLibro(datos, XLSX, filasPorHoja = MAX_FILAS_DATOS) {
  if (
    !datos ||
    !TABLAS.has(datos.tabla) ||
    !Array.isArray(datos.filas) ||
    !Array.isArray(datos.columnas) ||
    !datos.columnas.length ||
    String(datos.filas.length) !== datos.total
  ) {
    throw new Error("La exportación no está completa. No se descargó ningún archivo.");
  }
  if (!Number.isInteger(filasPorHoja) || filasPorHoja < 1 || filasPorHoja > MAX_FILAS_DATOS) {
    throw new Error("Tamaño de hoja inválido.");
  }
  const libro = XLSX.utils.book_new();
  const cabeceras = datos.columnas.map((c) => c.nombre);
  const hojas = Math.max(1, Math.ceil(datos.filas.length / filasPorHoja));
  for (let numero = 0; numero < hojas; numero++) {
    const inicio = numero * filasPorHoja;
    const filas = datos.filas.slice(inicio, inicio + filasPorHoja).map((fila) =>
      datos.columnas.map((columna) => {
        if (!Object.prototype.hasOwnProperty.call(fila, columna.nombre)) {
          throw new Error(`Falta la columna ${columna.nombre}. Se canceló la exportación.`);
        }
        return valorExcel(fila[columna.nombre], columna);
      }),
    );
    const hoja = XLSX.utils.aoa_to_sheet([cabeceras, ...filas]);
    hoja["!cols"] = cabeceras.map((nombre) => ({ wch: Math.min(40, Math.max(18, nombre.length + 2)) }));
    XLSX.utils.book_append_sheet(libro, hoja, hojas === 1 ? datos.tabla : `${datos.tabla}_${numero + 1}`);
  }
  const info = XLSX.utils.aoa_to_sheet([
    ["Tabla", datos.tabla],
    ["Fecha de exportación UTC", datos.exportado_en],
    ["Cantidad de registros", datos.filas.length],
    ["Alcance", "Todas las filas y columnas de la tabla; sin filtros"],
    ["Valores nulos", "Celdas vacías"],
    ["Fechas", "Texto ISO con zona horaria; sin conversión local"],
    ["Decimales e importes numeric", "Texto para conservar toda la precisión original"],
    ["Hojas de datos", hojas],
    [],
    ["Columna", "Tipo PostgreSQL"],
    ...datos.columnas.map((c) => [c.nombre, c.tipo]),
  ]);
  info["!cols"] = [{ wch: 32 }, { wch: 75 }];
  XLSX.utils.book_append_sheet(libro, info, "Exportacion");
  return libro;
}

export async function descargarTablaExcel(tabla, { signal, onEstado = () => {} } = {}) {
  if (!TABLAS.has(tabla)) throw new Error("Tabla no habilitada.");
  // Carga diferida: las otras pantallas no descargan la biblioteca de Excel.
  const [{ supabase }, XLSX] = await Promise.all([import("../supabaseClient"), import("xlsx")]);
  signal?.throwIfAborted();
  onEstado("Leyendo la tabla completa…");
  let consulta =
    tabla === "mantenimientos" ? supabase.rpc("exportar_mantenimientos") : supabase.rpc("exportar_tabla_completa", { p_tabla: tabla });
  if (signal) consulta = consulta.abortSignal(signal);
  const { data, error } = await consulta;
  signal?.throwIfAborted();
  if (error) throw new Error(error.message || "No se pudo leer la tabla completa.");
  onEstado("Preparando el archivo Excel…");
  await new Promise((resolve) => setTimeout(resolve, 0));
  signal?.throwIfAborted();
  const libro = construirLibro(data, XLSX);
  const bytes = XLSX.write(libro, { bookType: "xlsx", type: "array", compression: true });
  signal?.throwIfAborted();
  const fecha = new Date(data.exportado_en).toISOString().replace(/[:.]/g, "-");
  const nombre = `EGEO_${tabla}_${fecha}.xlsx`;
  const blob = new Blob([bytes], {
    type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  });
  const url = URL.createObjectURL(blob);
  const enlace = document.createElement("a");
  enlace.href = url;
  enlace.download = nombre;
  document.body.appendChild(enlace);
  enlace.click();
  enlace.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
  return { nombre, filas: data.filas.length };
}
