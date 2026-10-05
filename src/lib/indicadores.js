export const numero = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
export function resumen(tareas) {
  const r = { tareas: tareas.length, ok: 0, scrap: 0, real: 0, std: 0, realComparable: 0, comparables: 0 };
  for (const t of tareas) {
    r.ok += numero(t.piezas_ok);
    r.scrap += numero(t.piezas_scrap);
    r.real += numero(t.real_seg);
    if (numero(t.estandar) > 0 && numero(t.real_seg) > 0) {
      r.std += numero(t.std_seg);
      r.realComparable += numero(t.real_seg);
      r.comparables++;
    }
  }
  r.cumplimiento = r.realComparable > 0 ? (100 * r.std) / r.realComparable : null;
  r.scrapPct = r.ok + r.scrap > 0 ? (100 * r.scrap) / (r.ok + r.scrap) : null;
  r.porHora = r.real > 0 ? r.ok / (r.real / 3600) : null;
  r.desvio = r.std > 0 ? (100 * (r.realComparable - r.std)) / r.std : null;
  return r;
}
export function agrupar(tareas, modo) {
  const mapa = new Map();
  for (const t of tareas) {
    const key =
      modo === "orden" ? t.pedido_id : modo === "articulo" ? t.articulo_id : modo === "proceso" ? t.articulo_id + "|" + t.actividad : t.id;
    if (!mapa.has(key)) mapa.set(key, []);
    mapa.get(key).push(t);
  }
  return [...mapa.entries()]
    .map(([key, ts]) => ({
      key,
      nombre:
        modo === "orden"
          ? ts[0].pedido_codigo
          : modo === "articulo"
            ? ts[0].articulo_codigo + " — " + ts[0].articulo_nombre
            : modo === "proceso"
              ? ts[0].articulo_codigo + " / " + ts[0].actividad
              : ts[0].dia + " · " + ts[0].pedido_codigo + " · " + ts[0].actividad + " · " + ts[0].id.slice(0, 8),
      ...resumen(ts),
    }))
    .sort((a, b) => a.nombre.localeCompare(b.nombre));
}

const normalizarBusqueda = (valor) =>
  String(valor || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();
export function indexarCatalogo(catalogo) {
  return catalogo.map((articulo) => ({ articulo, texto: normalizarBusqueda(articulo.codigo + " " + articulo.nombre) }));
}
export function filtrarIndiceCatalogo(indice, categoria, busqueda) {
  const terminos = normalizarBusqueda(busqueda).split(/\s+/).filter(Boolean);
  return indice
    .filter(
      ({ articulo, texto }) =>
        (!categoria || (articulo.categoria || "Sin categoría") === categoria) && terminos.every((t) => texto.includes(t)),
    )
    .map(({ articulo }) => articulo);
}
export function filtrarCatalogo(catalogo, categoria, busqueda) {
  return filtrarIndiceCatalogo(indexarCatalogo(catalogo), categoria, busqueda);
}
export function cambiarSeleccion(actual, catalogo, ids, agregar) {
  const elegidos = new Set(actual === null ? catalogo.map((a) => a.id) : actual);
  for (const id of ids) {
    if (agregar) elegidos.add(id);
    else elegidos.delete(id);
  }
  return [...elegidos];
}
export function produccionDiaria(dias, tareas) {
  const mapa = new Map(dias.map((d) => [d.dia, { dia: d.dia, buenas: 0, scrap: 0 }]));
  for (const t of tareas) {
    if (t.es_ultimo && mapa.has(t.dia)) {
      mapa.get(t.dia).buenas += Number(t.piezas_ok) || 0;
      mapa.get(t.dia).scrap += Number(t.piezas_scrap) || 0;
    }
  }
  return [...mapa.values()];
}
