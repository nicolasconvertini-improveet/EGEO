import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { fileURLToPath, pathToFileURL } from "node:url";
const { chromium } = await import(
  process.env.EGEO_PLAYWRIGHT_MODULE ? pathToFileURL(process.env.EGEO_PLAYWRIGHT_MODULE).href : "playwright"
);
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const esbuild = require("esbuild");
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const stage = root;
const resultados = path.join(root, "test-results");
fs.mkdirSync(resultados, { recursive: true });
const fixture = `
export async function cargarIndicadores(consulta,signal){
 window.calls=(window.calls||0)+1;window.lastConsulta=consulta;
 await new Promise(r=>setTimeout(r,20));
 if(signal.aborted)throw new Error("Abortado");
 if(window.failRequest)throw new Error("Error de prueba");
 const catalogo=Array.from({length:250},(_,i)=>({id:"a"+i,codigo:"ART"+String(i).padStart(3,"0"),nombre:"Artículo "+i,categoria:i<125?"C1":"C2"}));
 const dias=[];
 for(let d=new Date(consulta.desde+"T12:00:00Z");d.toISOString().slice(0,10)<=consulta.hasta;d.setUTCDate(d.getUTCDate()+1)){
  dias.push({dia:d.toISOString().slice(0,10),tareas:1,piezas:90,ok:90,scrap:10,real:4444.2,pausas:1,pausa_seg:1800,ordenes:1,mantenimientos:1,mantenimiento_seg:3600,correctivo_seg:0});
 }
 return {...consulta,catalogo,dias,finalizadas_sin_fecha:0,sin_etapas:0,tareas:[{id:"t1",pedido_id:"p1",pedido_codigo:"P1",articulo_id:"a0",articulo_codigo:"ART000",articulo_nombre:"Artículo 0",actividad:"embolsado",dia:consulta.desde,piezas_ok:90,piezas_scrap:10,real_seg:4444.2,std_seg:5400,estandar:60,es_ultimo:true}]};
}
`;
const entry =
  'import React from "react";import {createRoot} from "react-dom/client";import Indicadores from "' +
  stage.replaceAll("\\", "/") +
  '/src/pages/Indicadores.jsx";createRoot(document.getElementById("root")).render(<React.StrictMode><div className="app-root"><div className="app"><div className="body"><Indicadores rol={window.testRole||"admin"}/></div></div></div></React.StrictMode>);';
const build = await esbuild.build({
  stdin: { contents: entry, resolveDir: root, loader: "jsx" },
  bundle: true,
  write: false,
  outdir: stage + "/ui",
  format: "iife",
  nodePaths: [root + "/node_modules"],
  plugins: [
    {
      name: "fixture",
      setup(b) {
        b.onLoad({ filter: /indicadoresApi\.js$/ }, () => ({ contents: fixture, loader: "js" }));
        b.onResolve({ filter: /constants$/ }, () => ({ path: root + "/src/lib/constants.js" }));
      },
    },
  ],
});
const js = build.outputFiles.find((f) => f.path.endsWith(".js")).text;
const css = build.outputFiles.find((f) => f.path.endsWith(".css")).text;
const common = fs.readFileSync(root + "/src/styles.css", "utf8").replace(/@import[^;]+;/g, "");
const browser = await chromium.launch({
  executablePath:
    process.env.EGEO_BROWSER_PATH ||
    (fs.existsSync("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe")
      ? "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
      : undefined),
  headless: true,
});
let n = 0;
const check = (ok, msg) => {
  assert.ok(ok, msg);
  n++;
};
async function mount(viewport, role = "admin") {
  const page = await browser.newPage({ viewport });
  await page.route("**/*", (route) => route.abort());
  await page.setContent('<html lang="es"><head><style>' + common + "\n" + css + '</style></head><body><div id="root"></div></body></html>');
  await page.evaluate((r) => (window.testRole = r), role);
  await page.addScriptTag({ content: js });
  return page;
}
try {
  const page = await mount({ width: 390, height: 844 });
  const errores = [];
  page.on("pageerror", (e) => errores.push(e.message));
  await page.getByText("Producción por día", { exact: true }).waitFor();
  check(!(await page.locator("#indicadores-filtros").isVisible()), "Filtros plegados");
  await page.getByRole("button", { name: "Mostrar filtros" }).click();
  await page.getByRole("button", { name: "Seleccionar artículos (250)", exact: true }).click();
  await page.locator("dialog[open]").waitFor();
  check(await page.getByPlaceholder("Código o nombre").evaluate((e) => e === document.activeElement), "Foco inicial");
  await page.getByRole("button", { name: "Quitar todos", exact: true }).click();
  await page.getByRole("button", { name: "Cancelar", exact: true }).click();
  check(await page.getByRole("button", { name: "Seleccionar artículos (250)", exact: true }).isVisible(), "Cancelar restaura");
  await page.getByRole("button", { name: "Seleccionar artículos (250)", exact: true }).click();
  await page.getByRole("button", { name: "Quitar todos", exact: true }).click();
  await page.locator("dialog").getByRole("combobox").selectOption("C1");
  await page.getByRole("button", { name: "Agregar todos los filtrados (125)", exact: true }).click();
  await page.locator("dialog").getByRole("combobox").selectOption("C2");
  await page.locator(".ind-modal-articulo input").first().check();
  check(await page.getByText("126 seleccionados", { exact: true }).isVisible(), "Selección entre categorías");
  await page.getByLabel("Ver solo seleccionados", { exact: true }).check();
  check((await page.locator(".ind-modal-articulo").count()) === 1, "Solo seleccionados respeta categoría");
  await page.locator("dialog").getByRole("combobox").selectOption("");
  check((await page.locator(".ind-modal-articulo").count()) === 100, "Límite de render inicial");
  await page.getByRole("button", { name: "Mostrar más (26)", exact: true }).click();
  check((await page.locator(".ind-modal-articulo").count()) === 126, "Mostrar más");
  const footer = await page.locator(".ind-modal-pie").boundingBox();
  check(footer.y + footer.height <= 844, "Pie visible móvil");
  await page.getByRole("button", { name: "Aplicar selección", exact: true }).click();
  check(await page.getByRole("button", { name: "Seleccionar artículos (126)", exact: true }).isVisible(), "Aplicar selección");
  await page.getByRole("button", { name: "Seleccionar artículos (126)", exact: true }).click();
  await page.getByRole("button", { name: "Quitar todos", exact: true }).click();
  await page.keyboard.press("Escape");
  check(
    await page.getByRole("button", { name: "Seleccionar artículos (126)", exact: true }).evaluate((e) => e === document.activeElement),
    "Escape restaura foco y cancela",
  );
  await page.getByRole("button", { name: "Consultar / actualizar", exact: true }).click();
  await page.waitForFunction(() => window.lastConsulta.articulos?.length === 126);
  await page.getByText("Producción por día", { exact: true }).waitFor();
  check(true, "Consulta recibe selección");
  await page.getByRole("button", { name: "Ocultar filtros" }).click();
  await page.getByText("Ver resumen de indicadores", { exact: true }).click();
  const cajas = await page.locator(".ind-tarjeta").evaluateAll((es) =>
    es.map((e) => {
      const r = e.getBoundingClientRect();
      return {
        y: r.y,
        h: r.height,
        title: e.querySelector("h2").getBoundingClientRect().y,
        value: e.querySelector("strong").getBoundingClientRect().y,
      };
    }),
  );
  check(cajas.length === 6 && Math.max(...cajas.map((r) => r.h)) - Math.min(...cajas.map((r) => r.h)) < 1, "Seis alturas iguales");
  check(Math.abs(cajas[0].y - cajas[1].y) < 1 && Math.abs(cajas[0].value - cajas[1].value) < 1, "Primera fila alineada");
  await page.getByText("Ver resumen de indicadores", { exact: true }).click();
  check(!(await page.getByText("Cómo leer estos indicadores", { exact: true }).isVisible()), "Ayuda se oculta con resumen");
  await page.locator(".ind-grafico").nth(1).getByText("Ver valores por día", { exact: true }).click();
  check((await page.locator(".ind-grafico").nth(1).innerText()).includes("1,23"), "Horas con dos decimales");
  await page.screenshot({ path: resultados + "/indicadores-movil.png", fullPage: true });
  await page.getByRole("button", { name: "Mostrar filtros" }).click();
  await page.setViewportSize({ width: 844, height: 390 });
  await page.getByRole("button", { name: "Seleccionar artículos (126)", exact: true }).click();
  const pie = await page.locator(".ind-modal-pie").boundingBox();
  check(pie.y + pie.height <= 390, "Pie visible en horizontal");
  const dialogBox = await page.locator("dialog").boundingBox();
  check(pie.y + pie.height <= dialogBox.y + dialogBox.height, "Pie dentro del diálogo sin recorte");
  await page.getByRole("button", { name: "Aplicar selección", exact: true }).focus();
  await page.keyboard.press("Tab");
  check(await page.locator("dialog").evaluate((e) => e.contains(document.activeElement)), "Foco contenido en modal");
  await page.setViewportSize({ width: 320, height: 568 });
  const pieChico = await page.locator(".ind-modal-pie").boundingBox();
  const dialogChico = await page.locator("dialog").boundingBox();
  check(pieChico.y + pieChico.height <= dialogChico.y + dialogChico.height, "Pie visible en pantalla pequeña");

  await page.screenshot({ path: resultados + "/selector-horizontal.png" });
  await page.keyboard.press("Escape");
  await page.evaluate(() => (window.failRequest = true));
  await page.getByRole("button", { name: "Consultar / actualizar", exact: true }).click();
  await page.getByRole("alert").waitFor();
  check(!(await page.getByText("Producción por día", { exact: true }).isVisible()), "Fallo no muestra resultados viejos");
  await page.evaluate(() => (window.failRequest = false));
  await page.getByRole("button", { name: "Reintentar última consulta", exact: true }).click();
  await page.getByText("Producción por día", { exact: true }).waitFor();
  check(true, "Reintento recupera la consulta");

  check(errores.length === 0, "Sin errores de React");
  await page.close();
  const denied = await mount({ width: 390, height: 844 }, "supervisor");
  await denied.getByRole("alert").waitFor();
  check(await denied.evaluate(() => !window.calls), "Supervisor no consulta API");
  await denied.close();
  console.log(n + " comprobaciones de navegador correctas, con datos simulados.");
} finally {
  await browser.close();
}
