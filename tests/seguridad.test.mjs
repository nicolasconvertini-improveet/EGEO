import test from "node:test";
import assert from "node:assert/strict";
import * as XLSX from "xlsx";
import { construirLibro } from "../src/lib/exportarExcel.js";
import { handler as crear } from "../netlify/functions/crear-usuario.js";
import { handler as cambiar } from "../netlify/functions/cambiar-password.js";
test("Endpoints administrativos rechazan anónimos, métodos incorrectos y cuerpos excesivos", async () => {
  for (const handler of [crear, cambiar]) {
    assert.equal((await handler({ httpMethod: "GET" })).statusCode, 405);
    assert.equal(
      (await handler({ httpMethod: "POST", headers: {}, body: "{}" }))
        .statusCode,
      401,
    );
    assert.equal(
      (
        await handler({
          httpMethod: "POST",
          headers: {},
          body: "é".repeat(9000),
        })
      ).statusCode,
      413,
    );
  }
});
test("Excel: duración utilizable como número y entradas maliciosas como texto sin fórmula", () => {
  const libro = construirLibro(
    {
      tabla: "tareas",
      total: "1",
      exportado_en: new Date().toISOString(),
      columnas: [
        { nombre: "duracion_minutos", tipo: "float8" },
        { nombre: "observaciones", tipo: "text" },
      ],
      filas: [
        {
          duracion_minutos: "1501.5",
          observaciones: '=HYPERLINK("https://example.com")',
        },
      ],
    },
    XLSX,
  );
  const bytes = XLSX.write(libro, { type: "buffer", bookType: "xlsx" });
  const hoja = XLSX.read(bytes, { type: "buffer" }).Sheets.tareas;
  assert.equal(hoja.A2.t, "n");
  assert.equal(hoja.A2.v, 1501.5);
  assert.equal(hoja.B2.t, "s");
  assert.equal(hoja.B2.f, undefined);
});

// Ejercitar la misma configuración que usa la compilación, sin publicar valores.
test("La compilación bloquea secretos en variables públicas", async () => {
  const { default: config } = await import("../vite.config.js");
  const nombre = "VITE_PRUEBA_SEGURIDAD";
  const anterior = process.env[nombre];
  try {
    for (const valor of [
      "sb_secret_solo_fixture",
      "eyJhbGciOiJIUzI1NiJ9." +
        Buffer.from(JSON.stringify({ role: "service_role" })).toString(
          "base64url",
        ) +
        ".firma_fixture",
    ]) {
      process.env[nombre] = valor;
      assert.throws(
        () => config({ mode: "development" }),
        /contiene un secreto/,
      );
    }
  } finally {
    if (anterior === undefined) delete process.env[nombre];
    else process.env[nombre] = anterior;
  }
});
