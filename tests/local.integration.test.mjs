import assert from "node:assert/strict";
import test from "node:test";
import { createClient } from "@supabase/supabase-js";
import { estadoLocal } from "../scripts/local-config.mjs";
const env = estadoLocal();
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const root = createClient(env.API_URL, env.SERVICE_ROLE_KEY, opts);
const must = async (query) => {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data;
};
const denied = async (query) => {
  const { error } = await query;
  assert.ok(error, "La operación debería rechazarse");
};
const stamp = "test-" + Date.now();
const pass = crypto.randomUUID() + "aA1!";
async function usuario(rol) {
  const email = `${stamp}-${rol}-${crypto.randomUUID().slice(0, 8)}@egeo.test`;
  const { user } = await must(
    root.auth.admin.createUser({
      email,
      password: pass,
      email_confirm: true,
      user_metadata: { nombre: rol },
    }),
  );
  await must(root.from("perfiles").update({ rol }).eq("id", user.id));
  const c = createClient(env.API_URL, env.ANON_KEY, opts);
  await must(c.auth.signInWithPassword({ email, password: pass }));
  return { id: user.id, c, email };
}
test("Docker local: órdenes por proceso, molde multiartículo, historial y permisos", async () => {
  const admin = await usuario("admin"),
    op = await usuario("operario"),
    otro = await usuario("supervisor");
  const a = await must(
    admin.c
      .from("articulos")
      .insert([
        {
          codigo: stamp + "A",
          nombre: "Pieza A",
          std_inyectado: 10,
          std_rebabado: 5,
        },
        {
          codigo: stamp + "B",
          nombre: "Pieza B",
          std_inyectado: 10,
          std_rebabado: 5,
        },
      ])
      .select(),
  );
  const maquina = await must(
    admin.c
      .from("maquinas")
      .insert({ codigo: stamp, nombre: "Inyectora de prueba" })
      .select()
      .single(),
  );
  const moldeDatos = {
    codigo: stamp,
    maquina_id: maquina.id,
    material: "PP",
    material_ciclo: 30,
    unidad_material: "g",
    segundos_ciclo: 20,
    activo: true,
  };
  const molde = await must(
    admin.c.rpc("guardar_molde", {
      p_id: null,
      p_datos: moldeDatos,
      p_articulos: a.map((x, i) => ({
        articulo_id: x.id,
        unidades_ciclo: i + 1,
      })),
    }),
  );
  await denied(
    op.c.rpc("guardar_molde", {
      p_id: null,
      p_datos: { ...moldeDatos, codigo: stamp + "X" },
      p_articulos: [],
    }),
  );
  await denied(
    admin.c.from("maquinas").update({ activo: false }).eq("id", maquina.id),
  );
  const pedido = await must(
    op.c
      .from("pedidos")
      .insert({
        codigo: stamp,
        proceso: "inyectado",
        molde_id: molde,
        cantidad: 10,
      })
      .select()
      .single(),
  );
  const detalle = await must(
    op.c.from("v_pedidos").select("*").eq("id", pedido.id).single(),
  );
  assert.equal(detalle.articulos.length, 2);
  await denied(
    op.c.rpc("gestionar_tarea", {
      p_accion: "iniciar",
      p_pedido: pedido.id,
      p_actividad: "armado",
    }),
  );
  const tid = await must(
    op.c.rpc("gestionar_tarea", {
      p_accion: "iniciar",
      p_pedido: pedido.id,
      p_actividad: "inyectado",
    }),
  );
  let t = await must(op.c.from("v_tareas").select("*").eq("id", tid).single());
  await must(
    op.c.rpc("gestionar_tarea", {
      p_accion: "finalizar",
      p_tarea: tid,
      p_revision: t.revision,
    }),
  );
  t = await must(op.c.from("v_tareas").select("*").eq("id", tid).single());
  await denied(
    op.c.rpc("gestionar_tarea", {
      p_accion: "confirmar",
      p_tarea: tid,
      p_revision: t.revision,
      p_ok: 30,
      p_scrap: 0,
    }),
  );
  const resultados = a.map((x, i) => ({
    articulo_id: x.id,
    piezas_ok: (i + 1) * 10,
    piezas_scrap: i,
  }));
  const params = {
    p_tarea: tid,
    p_revision: t.revision,
    p_resultados: resultados,
    p_observaciones: "",
  };
  await denied(
    op.c.rpc("confirmar_tarea_molde", {
      ...params,
      p_resultados: [resultados[0]],
    }),
  );
  await must(op.c.rpc("confirmar_tarea_molde", params));
  await must(op.c.rpc("confirmar_tarea_molde", params));
  t = await must(op.c.from("v_tareas").select("*").eq("id", tid).single());
  assert.equal(t.piezas_ok, 30);
  assert.equal(t.resultados.length, 2);
  assert.equal(t.std_seg, 200);
  const terminado = await must(
    op.c.from("v_pedidos").select("*").eq("id", pedido.id).single(),
  );
  assert.equal(terminado.estado, "finalizado");
  assert.equal(terminado.ok_acum, 10);
  await must(
    admin.c.rpc("guardar_molde", {
      p_id: molde,
      p_datos: { ...moldeDatos, segundos_ciclo: 99 },
      p_articulos: [{ articulo_id: a[0].id, unidades_ciclo: 3 }],
    }),
  );
  assert.equal(
    (
      await must(
        op.c.from("v_pedidos").select("*").eq("id", pedido.id).single(),
      )
    ).articulos.length,
    2,
  );
  assert.equal(
    (await must(op.c.from("v_tareas").select("*").eq("id", tid).single()))
      .std_seg,
    200,
  );
  await denied(
    admin.c.rpc("editar_cantidad_pedido", {
      p_pedido: pedido.id,
      p_cantidad: 9,
    }),
  );
  await must(
    admin.c.rpc("editar_cantidad_pedido", {
      p_pedido: pedido.id,
      p_cantidad: 11,
    }),
  );
  const normal = await must(
    op.c
      .from("pedidos")
      .insert({
        codigo: stamp + "R",
        proceso: "rebabado",
        articulo_id: a[0].id,
        cantidad: 1,
      })
      .select()
      .single(),
  );
  await denied(
    op.c
      .from("pedidos")
      .insert({ codigo: stamp + "ERR", articulo_id: a[0].id, cantidad: 1 }),
  );
  await denied(
    op.c.rpc("gestionar_tarea", {
      p_accion: "iniciar",
      p_pedido: normal.id,
      p_actividad: "inyectado",
    }),
  );
  const sid = crypto.randomUUID();
  await denied(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: sid,
      p_datos: { tipo: "molienda" },
    }),
  );
  const s = await must(
    admin.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: sid,
      p_datos: {
        tipo: "molienda",
        asignado_id: op.id,
        detalle: "Separar material por color\nNo mezclar PP y PE",
      },
    }),
  );
  assert.equal(s.estado, "asignada");
  assert.equal(s.detalle, "Separar material por color\nNo mezclar PP y PE");
  const otherOp = await usuario("operario"); // email único para un segundo operario
  const secret = await must(
    admin.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: crypto.randomUUID(),
      p_datos: { tipo: "molienda", asignado_id: otro.id },
    }),
  );
  assert.equal(
    (
      await must(
        op.c.from("solicitudes_trabajo").select("*").eq("id", secret.id),
      )
    ).length,
    0,
  );
  await denied(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: secret.id,
      p_revision: 0,
      p_datos: { minutos: 5 },
    }),
  );
  const started = await must(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "iniciar",
      p_id: sid,
      p_revision: 0,
    }),
  );
  const resolved = await must(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: sid,
      p_revision: started.revision,
      p_datos: {
        minutos: 30,
        resolucion: "Material molido y separado\nQuedó un remanente",
      },
    }),
  );
  assert.equal(resolved.estado, "resuelta");
  assert.equal(
    resolved.resolucion,
    "Material molido y separado\nQuedó un remanente",
  );
  const historialMolienda = await must(op.c.rpc("exportar_mantenimientos"));
  assert.equal(
    historialMolienda.filas.find((r) => r.id === sid).detalle,
    resolved.resolucion,
  );
  const opcionalId = crypto.randomUUID();
  await must(
    admin.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: opcionalId,
      p_datos: { tipo: "molienda", asignado_id: op.id },
    }),
  );
  await denied(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: opcionalId,
      p_revision: 0,
      p_datos: { minutos: 1, resolucion: "x".repeat(5001) },
    }),
  );
  const sinObservaciones = await must(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: opcionalId,
      p_revision: 0,
      p_datos: { minutos: 1 },
    }),
  );
  assert.equal(sinObservaciones.resolucion, "");
  assert.equal(
    (
      await must(
        op.c
          .from("solicitudes_trabajo")
          .select("*")
          .neq("estado", "resuelta")
          .eq("id", sid),
      )
    ).length,
    0,
  );
  const day = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
  }).format(new Date());
  const ind = await must(
    admin.c.rpc("indicadores_tablas", {
      p_desde: day,
      p_hasta: day,
      p_articulos: a.map((x) => x.id),
    }),
  );
  assert.deepEqual(
    ind.produccion
      .filter((r) => a.some((x) => x.id === r.articulo_id))
      .map((r) => Number(r.ok))
      .sort((a, b) => a - b),
    [10, 20],
  );
  assert.ok(
    ind.tiempos.some(
      (r) => r.motivo === "Molienda" && Number(r.segundos) >= 1800,
    ),
  );
  assert.ok(
    Math.abs(
      Number(ind.total_segundos) -
        ind.tiempos.reduce((s, r) => s + Number(r.segundos), 0),
    ) < 0.001,
  );
  await denied(op.c.rpc("indicadores_tablas", { p_desde: day, p_hasta: day }));

  const report = await must(
    admin.c.rpc("exportar_reporte", { p_reporte: "tareas" }),
  );
  const exported = report.filas.filter((r) => r.nro_orden === stamp);
  assert.equal(exported.length, 2);
  assert.deepEqual(
    exported.map((r) => Number(r.piezas_ok)).sort((a, b) => a - b),
    [10, 20],
  );
  const before = await must(
    op.c.from("v_pedidos").select("*").eq("id", pedido.id).single(),
  );
  assert.deepEqual(
    before.articulos.map((r) => Number(r.ok)).sort((a, b) => a - b),
    [10, 20],
  );
  const current = await must(
    admin.c.from("v_tareas").select("*").eq("id", tid).single(),
  );
  const changed = resultados.map((r, i) => ({ ...r, piezas_ok: i ? 19 : 9 }));
  const now = Date.now();
  await must(
    admin.c.rpc("admin_editar_tarea_molde", {
      p_tarea: tid,
      p_revision: current.revision,
      p_inicio: new Date(now - 3600000).toISOString(),
      p_fin: new Date(now - 10000).toISOString(),
      p_resultados: changed,
      p_observaciones: "Corrección de QA",
      p_motivo: "Prueba de corrección",
    }),
  );
  const corrected = await must(
    admin.c.from("v_tareas").select("*").eq("id", tid).single(),
  );
  assert.equal(corrected.piezas_ok, 28);
  assert.equal(corrected.std_seg, 180);
  await denied(
    op.c.rpc("admin_editar_tarea_molde", {
      p_tarea: tid,
      p_revision: corrected.revision,
      p_inicio: corrected.inicio,
      p_fin: corrected.fin,
      p_resultados: changed,
      p_observaciones: "",
      p_motivo: "Sin permiso",
    }),
  );
  const equipo = await must(
    admin.c
      .from("equipos")
      .insert({ codigo: stamp, nombre: "Compresor QA" })
      .select()
      .single(),
  );
  const maintId = crypto.randomUUID();
  await denied(
    admin.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: maintId,
      p_datos: { tipo: "mantenimiento", detalle: "Sin equipo" },
    }),
  );
  await must(
    admin.c.rpc("gestionar_solicitud", {
      p_accion: "crear",
      p_id: maintId,
      p_datos: {
        tipo: "mantenimiento",
        equipo_id: equipo.id,
        detalle: "Revisar compresor",
        asignado_id: otro.id,
      },
    }),
  );
  await denied(
    op.c.rpc("gestionar_solicitud", {
      p_accion: "asignar",
      p_id: maintId,
      p_revision: 0,
      p_datos: { asignado_id: op.id },
    }),
  );
  await denied(
    otro.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: maintId,
      p_revision: 0,
      p_datos: { minutos: 15 },
    }),
  );
  await must(
    otro.c.rpc("gestionar_solicitud", {
      p_accion: "resolver",
      p_id: maintId,
      p_revision: 0,
      p_datos: { minutos: 15, resolucion: "Cambio de filtro" },
    }),
  );
  assert.equal(
    (await must(op.c.from("mantenimientos").select("*").eq("id", maintId)))
      .length,
    0,
  );
  const ownHistory = await must(op.c.rpc("exportar_mantenimientos"));
  assert.ok(ownHistory.filas.every((r) => r.ejecutor_id === op.id));
  await denied(
    op.c.rpc("registrar_mantenimiento", {
      p_id: crypto.randomUUID(),
      p_ejecutor_id: otro.id,
      p_fecha_ejecucion: day,
      p_detalle: "Intento ajeno",
      p_preventivo: false,
      p_minutos: 1,
    }),
  );
  const filtered = await must(
    admin.c.rpc("indicadores_tablas", {
      p_desde: day,
      p_hasta: day,
      p_articulos: [a[0].id],
      p_operario: op.id,
    }),
  );
  assert.equal(filtered.produccion.length, 1);
  assert.equal(filtered.produccion[0].ok, 9);
  const productionTime = filtered.tiempos.find(
    (r) => r.motivo === "Producción · inyectado",
  );
  const allArticles = await must(
    admin.c.rpc("indicadores_tablas", {
      p_desde: day,
      p_hasta: day,
      p_articulos: a.map((x) => x.id),
      p_operario: op.id,
    }),
  );
  assert.equal(
    productionTime.segundos,
    allArticles.tiempos.find((r) => r.motivo === "Producción · inyectado")
      .segundos,
  );
  await denied(
    admin.c.rpc("indicadores_tablas", { p_desde: "2000-01-01", p_hasta: day }),
  );
  // Funciones administrativas locales: rutas reales, sin Netlify cloud.
  Object.assign(process.env, {
    SUPABASE_URL: env.API_URL,
    SUPABASE_SERVICE_ROLE_KEY: env.SERVICE_ROLE_KEY,
  });
  const { crearServidor } = await import("../scripts/local-server-core.mjs");
  const { handler } = await import("../netlify/functions/crear-usuario.js");
  const http = await import("node:http");
  const server = http.createServer(crearServidor({ "crear-usuario": handler }));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const url =
      "http://127.0.0.1:" +
      server.address().port +
      "/.netlify/functions/crear-usuario";
    assert.equal(
      (await fetch(url, { method: "POST", body: "{}" })).status,
      401,
    );
    const {
      data: { session },
    } = await admin.c.auth.getSession();
    const created = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + session.access_token,
      },
      body: JSON.stringify({
        email: stamp + "-http@egeo.test",
        password: pass,
        nombre: "Operario HTTP",
        rol: "operario",
      }),
    });
    assert.ok(created.ok, await created.text());
    const {
      data: { session: opSession },
    } = await op.c.auth.getSession();
    assert.equal(
      (
        await fetch(url, {
          method: "POST",
          headers: { Authorization: "Bearer " + opSession.access_token },
          body: "{}",
        })
      ).status,
      403,
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
  // Probar el cliente real de la interfaz, incluyendo sus mapeos y RPC.
  const { build } = await import("esbuild");
  const { mkdirSync } = await import("node:fs");
  mkdirSync(".local", { recursive: true });
  await build({
    stdin: {
      contents:
        "export * from './src/api.js'; export {cargarIndicadores} from './src/lib/indicadoresApi.js'; export {supabase} from './src/supabaseClient.js'; export {default as Editor} from './src/pages/TareaEditar.jsx';",
      resolveDir: process.cwd(),
    },
    bundle: true,
    platform: "node",
    format: "esm",
    packages: "external",
    outfile: ".local/frontend-test.mjs",
    define: {
      "import.meta.env.VITE_SUPABASE_URL": JSON.stringify(env.API_URL),
      "import.meta.env.VITE_SUPABASE_ANON_KEY": JSON.stringify(env.ANON_KEY),
    },
  });
  const api = await import("../.local/frontend-test.mjs");
  await must(
    api.supabase.auth.signInWithPassword({ email: op.email, password: pass }),
  );
  await api.createPedido({
    codigo: stamp + "-UI",
    proceso: "inyectado",
    moldeId: molde,
    cantidad: 2,
  });
  const uiPedido = (await api.fetchPedidos()).find(
    (p) => p.codigo === stamp + "-UI",
  );
  assert.equal(uiPedido.proceso, "inyectado");
  assert.equal(uiPedido.moldeId, molde);
  const uiId = await api.iniciarTarea({
    pedidoId: uiPedido.id,
    actividad: "inyectado",
  });
  let uiTarea = await api.fetchTareaActiva();
  assert.equal(uiTarea.id, uiId);
  assert.equal(uiTarea.moldeId, molde);
  await api.finalizarTarea(uiTarea);
  uiTarea = await api.fetchTareaActiva();
  const uiResultados = [
    { articulo_id: a[0].id, piezas_ok: 6, piezas_scrap: 1 },
  ];
  await api.confirmarTarea(uiTarea, {
    ok: 6,
    scrap: 1,
    resultados: uiResultados,
    observaciones: "",
  });
  await must(
    api.supabase.auth.signInWithPassword({
      email: admin.email,
      password: pass,
    }),
  );
  const uiConfirmada = (await api.fetchTareas()).find((t) => t.id === uiId);
  assert.equal(uiConfirmada.resultados.length, 1);
  await api.adminEditarTarea(uiConfirmada, {
    inicio: new Date(Date.now() - 5000).toISOString(),
    fin: new Date(Date.now() - 1000).toISOString(),
    ok: 6,
    scrap: 1,
    resultados: uiResultados,
    observaciones: "Validación UI",
    motivo: "Prueba del cliente",
  });
  const { createElement } = await import("react");
  const { renderToStaticMarkup } = await import("react-dom/server");
  const html = renderToStaticMarkup(
    createElement(api.Editor, {
      tars: [uiConfirmada],
      detail: { id: uiId },
      notify: () => {},
      reloadPeds: () => {},
      reloadTars: () => {},
      setDetail: () => {},
    }),
  );
  assert.ok(html.includes("Producción por artículo del molde"));
  assert.ok(html.includes(a[0].codigo));
  assert.ok(
    !html.includes('id="ed-ok"'),
    "La edición por molde no debe mostrar una cantidad global editable",
  );
  const panel = await api.cargarIndicadores(
    { desde: day, hasta: day, articulos: null, proceso: "", operario: "" },
    new AbortController().signal,
  );
  assert.ok(panel.tareas.some((t) => t.id === uiId));
  assert.equal(panel.dias.length, 1);
  assert.ok(panel.produccion.length > 0);
  assert.ok(panel.tiempos.length > 0);
  const realResumen = panel.dias.reduce((n, d) => n + Number(d.real), 0);
  const realTabla = panel.tiempos
    .filter((t) => t.motivo.startsWith("Producción · "))
    .reduce((n, t) => n + Number(t.segundos), 0);
  assert.ok(Math.abs(realResumen - realTabla) < 0.001);
  await api.supabase.auth.signOut();
  console.log("Datos de prueba identificados con prefijo " + stamp);
});
