import test from "node:test";
import assert from "node:assert/strict";
import {
  numero,
  resumen,
  agrupar,
  filtrarCatalogo,
  cambiarSeleccion,
  produccionDiaria,
  indexarCatalogo,
  filtrarIndiceCatalogo,
} from "../src/lib/indicadores.js";
import { fmt, horas, hoy, rango, validarPeriodo } from "../src/lib/indicadoresFormato.js";
import { validarRespuestaIndicadores } from "../src/lib/indicadoresContrato.js";
const tarea = {
  id: "t1",
  pedido_id: "p1",
  pedido_codigo: "P1",
  articulo_id: "a1",
  articulo_codigo: "A1",
  articulo_nombre: "Artículo",
  actividad: "inyectado",
  dia: "2026-10-01",
  piezas_ok: 90,
  piezas_scrap: 10,
  real_seg: 5400,
  std_seg: 5400,
  estandar: 60,
  es_ultimo: true,
};
const catalogo = [
  { id: "a1", codigo: "A1", nombre: "Artículo Uno", categoria: "C1" },
  { id: "a2", codigo: "B2", nombre: "Dos", categoria: "C2" },
  { id: "a3", codigo: "C3", nombre: "Tres", categoria: null },
];
test("eficiencia ponderada, scrap y productividad", () => {
  const r = resumen([tarea]);
  assert.equal(r.cumplimiento, 100);
  assert.equal(r.scrapPct, 10);
  assert.equal(r.porHora, 60);
  assert.equal(r.desvio, 0);
  assert.equal(resumen([tarea, { ...tarea, real_seg: 10800 }]).cumplimiento, (100 * 10800) / 16200);
});
test("sin estándar o duración: excluir solo de comparables", () => {
  const r = resumen([tarea, { ...tarea, estandar: 0, real_seg: 100 }]);
  assert.equal(r.real, 5500);
  assert.equal(r.realComparable, 5400);
  assert.equal(r.comparables, 1);
  assert.equal(r.cumplimiento, 100);
  assert.equal(resumen([{ ...tarea, estandar: null }]).cumplimiento, null);
  assert.equal(resumen([{ ...tarea, real_seg: 0 }]).porHora, null);
});
test("cero producción conserva el costo de tiempo", () => {
  const r = resumen([{ ...tarea, piezas_ok: 0, piezas_scrap: 0, std_seg: 0 }]);
  assert.equal(r.cumplimiento, 0);
  assert.equal(r.desvio, null);
  assert.equal(r.scrapPct, null);
  assert.equal(resumen([]).cumplimiento, null);
  assert.equal(numero(Infinity), 0);
});
test("agrupación estable por entidad y proceso", () => {
  const otra = { ...tarea, id: "t2", actividad: "embolsado" };
  assert.equal(agrupar([tarea, otra], "proceso").length, 2);
  assert.equal(agrupar([tarea, otra], "orden").length, 1);
  assert.equal(agrupar([tarea, otra], "orden")[0].key, agrupar([otra, tarea], "orden")[0].key);
});
test("no duplicar producción entre etapas", () => {
  assert.deepEqual(produccionDiaria([{ dia: tarea.dia }, { dia: "2026-10-02" }], [tarea, { ...tarea, es_ultimo: false }]), [
    { dia: tarea.dia, buenas: 90, scrap: 10 },
    { dia: "2026-10-02", buenas: 0, scrap: 0 },
  ]);
});
test("búsqueda por palabras y acentos, categoría y catálogo indexado", () => {
  assert.deepEqual(
    filtrarCatalogo(catalogo, "C1", "uno articulo").map((a) => a.id),
    ["a1"],
  );
  assert.deepEqual(
    filtrarCatalogo(catalogo, "Sin categoría", "").map((a) => a.id),
    ["a3"],
  );
  assert.deepEqual(filtrarIndiceCatalogo(indexarCatalogo(catalogo), "C2", "dos"), [catalogo[1]]);
});
test("selección independiente sin mutación ni duplicados", () => {
  const actual = ["a1"];
  const nueva = cambiarSeleccion(actual, catalogo, ["a2"], true);
  assert.deepEqual(actual, ["a1"]);
  assert.deepEqual(nueva, ["a1", "a2"]);
  assert.deepEqual(cambiarSeleccion(nueva, catalogo, ["a1"], false), ["a2"]);
  assert.deepEqual(cambiarSeleccion(actual, catalogo, ["a1"], true), ["a1"]);
  assert.deepEqual(cambiarSeleccion(null, catalogo, ["a2"], false), ["a1", "a3"]);
  assert.deepEqual(cambiarSeleccion([], catalogo, [], true), []);
});
test("hasta dos decimales en horas, sin alterar precisión de cálculo", () => {
  assert.equal(horas(4444.2), "1,23 h");
  assert.equal(horas(3600), "1 h");
  assert.equal(fmt(1.2, 2), "1,2");
  assert.equal(fmt(null), "No aplica");
  assert.equal(fmt(Infinity), "No aplica");
});
test("fechas de Argentina independientes de la zona del navegador", () => {
  const fecha = new Date("2026-10-05T01:00:00Z");
  assert.equal(hoy(fecha), "2026-10-04");
  assert.deepEqual(rango("semana", fecha), { desde: "2026-09-28", hasta: "2026-10-04" });
  assert.deepEqual(rango("mes", fecha), { desde: "2026-10-01", hasta: "2026-10-04" });
});
test("rango válido e inclusivo; rechazar fechas inexistentes o futuras", () => {
  assert.equal(validarPeriodo("2026-01-01", "2026-04-03", "2026-10-05"), "");
  for (const fechas of [
    ["2026-01-01", "2026-04-04"],
    ["2026-02-30", "2026-03-01"],
    ["2026-10-02", "2026-10-01"],
    ["2026-10-05", "2026-10-06"],
  ]) {
    assert.notEqual(validarPeriodo(...fechas, "2026-10-05"), "");
  }
});
const consulta = { desde: "2026-10-01", hasta: "2026-10-01" };
const respuesta = () => ({
  ...consulta,
  tareas: [{ ...tarea }],
  catalogo: catalogo.map((a) => ({ ...a })),
  dias: [
    {
      dia: "2026-10-01",
      tareas: 1,
      piezas: 90,
      ok: 90,
      scrap: 10,
      real: 5400,
      pausas: 1,
      pausa_seg: 1800,
      ordenes: 0,
      mantenimientos: 0,
      mantenimiento_seg: 0,
      correctivo_seg: 0,
    },
  ],
});
test("contrato completo acepta la respuesta sin modificarla", () => {
  const data = respuesta();
  assert.equal(validarRespuestaIndicadores(data, consulta), data);
});
test("rechazar días faltantes, repetidos o de otra consulta", () => {
  for (const cambiar of [(d) => (d.dias = []), (d) => d.dias.push({ ...d.dias[0] }), (d) => (d.desde = "2026-09-30")]) {
    const data = respuesta();
    cambiar(data);
    assert.throws(() => validarRespuestaIndicadores(data, consulta));
  }
});
test("rechazar cantidades corruptas y tareas duplicadas", () => {
  for (const cambiar of [
    (d) => d.tareas.push({ ...d.tareas[0] }),
    (d) => (d.tareas[0].real_seg = "error"),
    (d) => (d.dias[0].real = -1),
    (d) => d.catalogo.push({ ...d.catalogo[0] }),
  ]) {
    const data = respuesta();
    cambiar(data);
    assert.throws(() => validarRespuestaIndicadores(data, consulta));
  }
});
