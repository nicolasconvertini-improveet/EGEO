// Reglas de inyectado sobre la configuración congelada de la orden.
export function analizarCiclos(
  articulos,
  resultados = [],
  segundosCiclo = 0,
  realSec = 0,
) {
  const errores = [];
  const filas = articulos.map((a) => {
    const r = resultados.find((r) => r.articulo_id === a.articulo_id) || {};
    const ok = Number(r.piezas_ok ?? 0),
      scrap = Number(r.piezas_scrap ?? 0),
      unidades = Number(a.unidades_ciclo),
      total = ok + scrap;
    let error = "";
    if (!Number.isInteger(unidades) || unidades <= 0)
      error =
        "La matriz de " + a.codigo + " no tiene unidades por ciclo válidas.";
    else if (
      !Number.isSafeInteger(ok) ||
      !Number.isSafeInteger(scrap) ||
      ok < 0 ||
      scrap < 0
    )
      error =
        "Las cantidades de " + a.codigo + " deben ser enteros no negativos.";
    else if (total % unidades !== 0)
      error =
        a.codigo +
        ": OK + scrap (" +
        total +
        ") debe ser múltiplo de " +
        unidades +
        ".";
    if (error) errores.push(error);
    return {
      ...a,
      ok,
      scrap,
      total,
      ciclos: error ? null : total / unidades,
      error,
    };
  });
  if (!filas.length)
    errores.push("No se encontró la matriz de artículos de la orden.");
  const ciclosPorArticulo = filas.map((f) => f.ciclos);
  if (!errores.length && new Set(ciclosPorArticulo).size > 1) {
    errores.push(
      "Todos los artículos deben corresponder a la misma cantidad de ciclos: " +
        filas.map((f) => `${f.codigo}: ${f.ciclos}`).join(" · ") +
        ".",
    );
  }
  const ciclos = errores.length ? null : ciclosPorArticulo[0];
  return {
    filas,
    errores,
    ciclos,
    ciclosPorArticulo,
    estandarSeg: ciclos == null ? null : ciclos * Number(segundosCiclo),
    productividad:
      ciclos == null || !(Number(segundosCiclo) > 0) || !(Number(realSec) > 0)
        ? null
        : (100 * ciclos * Number(segundosCiclo)) / Number(realSec),
  };
}
export function avanceInyectado(pedido, resultados = []) {
  const solicitados = Number(pedido?.cantidad) || 0,
    gramosCiclo = Number(pedido?.configuracion?.material_ciclo) || 0;
  const articulos = (pedido?.articulos || []).map((a) => {
    const r = resultados.find((r) => r.articulo_id === a.articulo_id) || {};
    const objetivo = solicitados * Number(a.unidades_ciclo);
    const ok = Number(a.ok || 0) + Number(r.piezas_ok || 0);
    const scrap = Number(a.scrap || 0) + Number(r.piezas_scrap || 0);
    return {
      ...a,
      solicitado: objetivo,
      ok,
      scrap,
      pendiente: Math.max(0, objetivo - ok),
    };
  });
  const ciclosPendientes = Math.max(
    0,
    ...articulos.map((a) => Math.ceil(a.pendiente / Number(a.unidades_ciclo))),
  );
  return {
    articulos,
    ciclosSolicitados: solicitados,
    ciclosPendientes,
    unidadesSolicitadas: articulos.reduce((n, a) => n + a.solicitado, 0),
    unidadesPendientes: articulos.reduce((n, a) => n + a.pendiente, 0),
    gramosSolicitados: solicitados * gramosCiclo,
    gramosPendientes: ciclosPendientes * gramosCiclo,
  };
}
