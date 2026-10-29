import assert from "node:assert/strict";
import test from "node:test";
import { analizarCiclos, avanceInyectado } from "../src/lib/inyectado.js";
const articulos = [
  {
    articulo_id: "A",
    codigo: "A",
    nombre: "Pieza A",
    unidades_ciclo: 2,
    ok: 0,
    scrap: 0,
  },
  {
    articulo_id: "B",
    codigo: "B",
    nombre: "Pieza B",
    unidades_ciclo: 3,
    ok: 0,
    scrap: 0,
  },
];
const resultados = [
  { articulo_id: "A", piezas_ok: 9, piezas_scrap: 1 },
  { articulo_id: "B", piezas_ok: 14, piezas_scrap: 1 },
];
test("Inyectado: productividad por ciclos ejecutados, incluyendo scrap y sin sumar tiempos por artículo", () => {
  const r = analizarCiclos(articulos, resultados, 20, 200);
  assert.deepEqual(r.errores, []);
  assert.equal(r.ciclos, 5);
  assert.equal(r.estandarSeg, 100);
  assert.equal(r.productividad, 50);
});
test("Inyectado: rechazar sumas que no sean múltiplos de la matriz", () => {
  const r = analizarCiclos(
    articulos,
    [{ ...resultados[0], piezas_ok: 8 }, resultados[1]],
    20,
    200,
  );
  assert.ok(r.errores.some((e) => e.includes("múltiplo de 2")));
  assert.equal(r.productividad, null);
});
test("Inyectado: múltiplos válidos deben representar la misma cantidad de ciclos", () => {
  const r = analizarCiclos(
    articulos,
    [resultados[0], { ...resultados[1], piezas_ok: 17 }],
    20,
    200,
  );
  assert.ok(r.errores.some((e) => e.includes("misma cantidad de ciclos")));
  assert.equal(r.productividad, null);
});
test("Inyectado: todo scrap también cuenta como ciclos; sin tiempo neto no dividir por cero", () => {
  const scrap = [
    { articulo_id: "A", piezas_ok: 0, piezas_scrap: 10 },
    { articulo_id: "B", piezas_ok: 0, piezas_scrap: 15 },
  ];
  assert.equal(analizarCiclos(articulos, scrap, 20, 200).productividad, 50);
  assert.equal(analizarCiclos(articulos, scrap, 20, 0).productividad, null);
  assert.equal(analizarCiclos(articulos, [], 20, 200).ciclos, 0);
});
test("Inyectado: cantidades enteras no negativas y matriz completa", () => {
  assert.ok(
    analizarCiclos(articulos, [
      { ...resultados[0], piezas_ok: -1 },
      resultados[1],
    ]).errores.length,
  );
  assert.ok(
    analizarCiclos(articulos, [
      { ...resultados[0], piezas_ok: 1.5 },
      resultados[1],
    ]).errores.length,
  );
  assert.ok(analizarCiclos([], []).errores.length);
});
test("Avance: unidades y gramos solicitados/pendientes, conservando la configuración de la orden", () => {
  const p = { cantidad: 10, configuracion: { material_ciclo: 30 }, articulos };
  const a = avanceInyectado(p, resultados);
  assert.equal(a.unidadesSolicitadas, 50);
  assert.equal(a.unidadesPendientes, 27);
  assert.equal(a.gramosSolicitados, 300);
  assert.equal(a.gramosPendientes, 180);
  assert.equal(a.ciclosPendientes, 6);
  assert.deepEqual(
    a.articulos.map((x) => x.pendiente),
    [11, 16],
  );
  assert.equal(p.articulos[0].ok, 0);
});
test("Avance: solo OK reduce pendientes; ningún pendiente negativo al superar el objetivo", () => {
  const p = { cantidad: 10, configuracion: { material_ciclo: 30 }, articulos };
  const rechazo = [
    { articulo_id: "A", piezas_ok: 0, piezas_scrap: 20 },
    { articulo_id: "B", piezas_ok: 0, piezas_scrap: 30 },
  ];
  assert.equal(avanceInyectado(p, rechazo).gramosPendientes, 300);
  const exceso = articulos.map((a) => ({
    articulo_id: a.articulo_id,
    piezas_ok: 11 * a.unidades_ciclo,
    piezas_scrap: 0,
  }));
  assert.equal(avanceInyectado(p, exceso).gramosPendientes, 0);
  assert.equal(avanceInyectado(p, exceso).unidadesPendientes, 0);
});
