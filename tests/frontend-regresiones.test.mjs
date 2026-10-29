import assert from "node:assert/strict";
import test from "node:test";
import { mkdirSync } from "node:fs";
import { build } from "esbuild";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  tarjetasTrabajos,
  filtrarTrabajos,
  ESTADOS_TRABAJO,
} from "../src/lib/trabajos.js";
mkdirSync(".local", { recursive: true });
await build({
  stdin: {
    contents: `export {ResumenRegistro} from './src/pages/Registrar.jsx';export {default as Planta} from './src/pages/Planta.jsx';export {default as Articulos} from './src/pages/Articulos.jsx';export {default as Selector} from './src/components/SelectorArticuloPedido.jsx';export {TarjetasTrabajos} from './src/components/PendientesTrabajo.jsx';`,
    resolveDir: process.cwd(),
  },
  bundle: true,
  platform: "node",
  format: "esm",
  packages: "external",
  outfile: ".local/regresiones-ui.mjs",
  define: {
    "import.meta.env.VITE_SUPABASE_URL": JSON.stringify(
      "http://127.0.0.1:54321",
    ),
    "import.meta.env.VITE_SUPABASE_ANON_KEY": JSON.stringify("test-only"),
  },
});
const ui = await import("../.local/regresiones-ui.mjs");
const arts = Array.from({ length: 25 }, (_, i) => ({
  id: "a" + i,
  codigo: "P" + String(i).padStart(2, "0"),
  nombre: "Pieza " + i,
  activo: true,
  categoria: i % 2 ? "Tapas" : "Bases",
  std: { inyectado: 1, rebabado: 1 },
}));
test("Planta: las tres secciones y Nuevo registro están en una misma barra", () => {
  const html = renderToStaticMarkup(
    createElement(ui.Planta, { rol: "admin", arts }),
  );
  const toolbar = html.match(/<div class="planta-toolbar"[\s\S]*?<\/div>/)?.[0];
  assert.ok(toolbar);
  assert.equal((toolbar.match(/<button/g) || []).length, 4);
  for (const text of ["Moldes", "Máquinas", "Equipos", "Nuevo registro"])
    assert.ok(toolbar.includes(text));
});
test("Artículos: selector de categorías visible incluso con artículos sin categoría", () => {
  for (const items of [
    arts,
    arts.map((a) => ({ ...a, categoria: null })),
    [],
  ]) {
    const html = renderToStaticMarkup(
      createElement(ui.Articulos, { arts: items, setDetail: () => {} }),
    );
    assert.ok(html.includes("Todas las categorías"));
  }
});
test("Nueva orden: recuperar búsqueda, categorías, resultados incrementales y ficha seleccionada", () => {
  const html = renderToStaticMarkup(
    createElement(ui.Selector, { arts, artId: "", onChange: () => {} }),
  );
  for (const text of [
    "Buscar por código o descripción",
    "Categoría (opcional)",
    "Todas las categorías",
    "Mostrando 20 de 25 artículos",
    "Ver más resultados",
  ])
    assert.ok(html.includes(text), text);
  assert.equal((html.match(/class="art-picker-option"/g) || []).length, 20);
  const selected = renderToStaticMarkup(
    createElement(ui.Selector, { arts, artId: arts[0].id, onChange: () => {} }),
  );
  assert.ok(selected.includes("Cambiar artículo"));
  assert.ok(selected.includes("Tiempos estándar por pieza"));
});
test("Tablero: seis tarjetas accionables, sin resueltas ni detalle; cada clic abre Trabajos con tipo y estado", () => {
  const rows = [
    {
      id: "1",
      tipo: "mantenimiento",
      estado: "pendiente",
      detalle: "DETALLE QUE NO DEBE MOSTRARSE",
    },
    { id: "2", tipo: "mantenimiento", estado: "asignada" },
    { id: "3", tipo: "molienda", estado: "en_curso" },
    { id: "4", tipo: "molienda", estado: "resuelta" },
  ];
  const rutas = [];
  const element = ui.TarjetasTrabajos({
    rows,
    irA: (...args) => rutas.push(args),
  });
  const buttons = [];
  function recorrer(node) {
    if (!node || typeof node !== "object") return;
    if (node.type === "button") buttons.push(node);
    for (const child of [].concat(node.props?.children || []).flat(Infinity))
      recorrer(child);
  }
  recorrer(element);
  assert.equal(buttons.length, 6);
  buttons.forEach((b) => b.props.onClick());
  for (const [index, [tab, filtro]] of rutas.entries()) {
    assert.equal(tab, "mantenimiento");
    const tarjeta = tarjetasTrabajos(rows)[index];
    assert.deepEqual(filtro, { tipo: tarjeta.tipo, estado: tarjeta.estado });
    assert.equal(filtrarTrabajos(rows, filtro).length, tarjeta.cantidad);
  }
  const html = renderToStaticMarkup(element);
  assert.ok(!html.includes("DETALLE QUE NO DEBE MOSTRARSE"));
  assert.ok(!html.includes("Resuelta"));
  assert.ok(rutas.every(([, filtro]) => filtro.estado !== "resuelta"));
  assert.equal(new Set(ESTADOS_TRABAJO.map((e) => e.key)).size, 4);
  assert.equal(ESTADOS_TRABAJO.filter((e) => e.key === "pendiente").length, 1);
});

test("Cierre de inyectado: mostrar productividad y avance en unidades y gramos", () => {
  const pedido = {
    cantidad: 10,
    configuracion: { codigo: "M-01", material_ciclo: 30, segundos_ciclo: 20 },
    articulos: [
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
    ],
  };
  const hecha = {
    molde: "M-01",
    act: "inyectado",
    ok: 23,
    scrap: 2,
    realSec: 200,
    productividad: 50,
    ciclos: 5,
    segundosCiclo: 20,
    gramosProcesados: 150,
    pedido,
    resultados: [
      { articulo_id: "A", piezas_ok: 9, piezas_scrap: 1 },
      { articulo_id: "B", piezas_ok: 14, piezas_scrap: 1 },
    ],
  };
  const html = renderToStaticMarkup(
    createElement(ui.ResumenRegistro, { hecha, onOtra: () => {} }),
  );
  for (const texto of [
    "50%",
    "5",
    "20",
    "150",
    "Material solicitado",
    "300",
    "Material pendiente estimado",
    "180",
    "Unidades solicitadas",
    "Unidades pendientes",
    "27",
  ])
    assert.ok(html.includes(texto), texto);
  assert.ok(html.includes("Registrar otra tarea"));
});
