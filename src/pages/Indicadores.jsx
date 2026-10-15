import React, { useEffect, useMemo, useState } from "react";
import { cargarIndicadores } from "../lib/indicadoresApi";
import { fmt, horas, pct, hoy, rango, validarPeriodo, TAMANO_PAGINA_INDICADORES } from "../lib/indicadoresFormato";
import ColumnasApiladas from "../components/ColumnasApiladas";
import { ACTS } from "../lib/constants";
import { resumen, agrupar, numero, produccionDiaria } from "../lib/indicadores";
import "../indicadores.css";
import SelectorArticulosIndicadores from "../components/SelectorArticulosIndicadores";
const VACIO = [];
const SERIES_PRODUCCION = [
  { key: "buenas", label: "Buenas", color: "var(--good)" },
  { key: "scrap", label: "Scrap", color: "var(--bad)" },
];
const SERIES_TIEMPOS = [
  { key: "produccion", label: "Producción", color: "var(--good)" },
  { key: "pausas", label: "Pausas", color: "var(--warn)" },
  { key: "mantenimiento", label: "Mantenimiento", color: "#4369a8" },
];
export default function Indicadores({ rol }) {
  const [form, setForm] = useState(() => ({ ...rango("semana"), articulos: null, proceso: "", operario: "" }));
  const [consulta, setConsulta] = useState(form),
    [tick, setTick] = useState(0);
  const [filtrosAbiertos, setFiltrosAbiertos] = useState(false);
  const [datos, setDatos] = useState(null),
    [error, setError] = useState(""),
    [cargando, setCargando] = useState(true);
  const [modo, setModo] = useState("proceso"),
    [pagina, setPagina] = useState(1);
  const [catalogo, setCatalogo] = useState([]);
  const [usuarios, setUsuarios] = useState([]);
  const [selectorAbierto, setSelectorAbierto] = useState(false);
  const [errorFormulario, setErrorFormulario] = useState("");
  const permitido = rol === "admin";
  useEffect(() => {
    if (!permitido) return;
    const ac = new AbortController();
    let vigente = true;
    setCargando(true);
    setError("");
    setDatos(null);
    setPagina(1);
    cargarIndicadores(consulta, ac.signal)
      .then((data) => {
        if (!vigente) return;
        setDatos(data);
        setCatalogo(data.catalogo);
        setUsuarios(data.usuarios || []);
      })
      .catch((e) => {
        if (vigente) setError(e.message || "No se pudieron cargar los indicadores");
      })
      .finally(() => {
        if (vigente) setCargando(false);
      });
    return () => {
      vigente = false;
      ac.abort();
    };
  }, [consulta, tick, permitido]);
  const ts = datos?.tareas || VACIO,
    ds = datos?.dias || VACIO;
  const r = useMemo(() => resumen(ts), [ts]);
  const grupos = useMemo(() => agrupar(ts, modo), [ts, modo]);
  const totales = useMemo(
    () =>
      ds.reduce((total, d) => {
        for (const k of ["ordenes", "piezas", "real", "pausa_seg", "mantenimientos", "mantenimiento_seg", "correctivo_seg", "pausas"])
          total[k] = (total[k] || 0) + numero(d[k]);
        return total;
      }, {}),
    [ds],
  );
  const suma = (k) => totales[k] || 0;
  const produccion = useMemo(() => produccionDiaria(ds, ts), [ds, ts]);
  const tiempos = useMemo(
    () =>
      ds.map((d) => ({
        dia: d.dia,
        produccion: numero(d.real) / 3600,
        pausas: numero(d.pausa_seg) / 3600,
        mantenimiento: numero(d.mantenimiento_seg) / 3600,
      })),
    [ds],
  );
  const paginas = Math.max(1, Math.ceil(grupos.length / TAMANO_PAGINA_INDICADORES));
  const aplicar = (e) => {
    e.preventDefault();
    const error = validarPeriodo(form.desde, form.hasta);
    setErrorFormulario(error);
    if (error) return;
    setConsulta({ ...form });
    setTick((n) => n + 1);
  };
  if (!permitido) return <p role="alert">Tu rol no tiene acceso a indicadores.</p>;
  return (
    <section className="ind">
      <button
        type="button"
        className="btn btn-ghost ind-plegar-filtros"
        aria-expanded={filtrosAbiertos}
        aria-controls="indicadores-filtros"
        onClick={() => setFiltrosAbiertos((v) => !v)}
      >
        <span>{filtrosAbiertos ? "Ocultar filtros" : "Mostrar filtros"}</span>
        <span aria-hidden="true">{filtrosAbiertos ? "▴" : "▾"}</span>
      </button>
      <div id="indicadores-filtros" hidden={!filtrosAbiertos}>
        <form className="card ind-filtros" onSubmit={aplicar}>
          <div className="ind-atajos">
            {[
              ["hoy", "Hoy"],
              ["semana", "Esta semana"],
              ["mes", "Este mes"],
            ].map(([v, l]) => (
              <button type="button" key={v} className="btn btn-ghost" onClick={() => setForm((f) => ({ ...f, ...rango(v) }))}>
                {l}
              </button>
            ))}
          </div>
          <label>
            Desde
            <input required type="date" value={form.desde} max={hoy()} onChange={(e) => setForm({ ...form, desde: e.target.value })} />
          </label>
          <label>
            Hasta
            <input required type="date" value={form.hasta} max={hoy()} onChange={(e) => setForm({ ...form, hasta: e.target.value })} />
          </label>
          <div className="ind-selector-abrir">
            <span>Artículos</span>
            <button
              type="button"
              className="btn btn-ghost"
              aria-haspopup="dialog"
              disabled={cargando || !datos}
              onClick={() => setSelectorAbierto(true)}
            >
              Seleccionar artículos ({form.articulos === null ? catalogo.length : form.articulos.length})
            </button>
          </div>
          <label>
            Proceso
            <select value={form.proceso} onChange={(e) => setForm({ ...form, proceso: e.target.value })}>
              <option value="">Todos</option>
              {ACTS.map((a) => (
                <option key={a.key} value={a.key}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Usuario
            <select value={form.operario} onChange={(e) => setForm({ ...form, operario: e.target.value })}>
              <option value="">Todos</option>
              {usuarios.map((u) => (
                <option key={u.id} value={u.id}>
                  {u.nombre}
                </option>
              ))}
            </select>
          </label>
          {errorFormulario && (
            <p className="ind-error-formulario" role="alert">
              {errorFormulario}
            </p>
          )}
          <button className="btn btn-primary" disabled={cargando}>
            Consultar / actualizar
          </button>
        </form>
      </div>
      {selectorAbierto && (
        <SelectorArticulosIndicadores
          catalogo={catalogo}
          valor={form.articulos}
          onCerrar={() => setSelectorAbierto(false)}
          onAplicar={(articulos) => {
            setForm((f) => ({ ...f, articulos }));
            setSelectorAbierto(false);
          }}
        />
      )}
      {cargando && <p role="status">Cargando indicadores…</p>}
      {error && (
        <div className="card" role="alert">
          {error}
          <button className="btn btn-ghost" onClick={() => setTick((n) => n + 1)}>
            Reintentar última consulta
          </button>
        </div>
      )}
      {datos && !cargando && (
        <>
          <p className="ind-nota">
            Período consultado: {consulta.desde} al {consulta.hasta}. Artículos:{" "}
            {consulta.articulos === null ? "todos" : consulta.articulos.length + " seleccionados"}. Proceso: {consulta.proceso || "todos"}.
            Usuario: {consulta.operario ? usuarios.find((u) => u.id === consulta.operario)?.nombre || "seleccionado" : "todos"}.
            {consulta.operario && " Órdenes terminadas y mantenimiento no dependen del usuario."}
          </p>
          {!ts.length && (
            <p role="status">
              No hay tareas confirmadas terminadas en este período para esos filtros. Las pausas y mantenimientos pueden tener registros.
            </p>
          )}
          <ColumnasApiladas
            titulo="Producción por día"
            filas={produccion}
            unidad="piezas"
            series={SERIES_PRODUCCION}
            nota="Buenas y scrap del último proceso aplicable. Cantidades asignadas al día de fin de cada tarea confirmada."
          />
          <ColumnasApiladas
            titulo="Tiempos por día"
            filas={tiempos}
            unidad="horas"
            decimales={2}
            series={SERIES_TIEMPOS}
            nota="Suma de tiempos registrados; pueden superponerse y no equivalen a la jornada trabajada. Mantenimiento incluye toda la planta."
          />
          <details className="ind-resumen">
            <summary>Ver resumen de indicadores</summary>
            <div className="ind-tarjetas">
              <Tarjeta
                titulo="Órdenes terminadas"
                valor={fmt(suma("ordenes"), 0)}
                ayuda="Primer cierre completo registrado por orden. El filtro de proceso no modifica este total."
              />
              <Tarjeta
                titulo="Piezas en último proceso"
                valor={fmt(suma("piezas"), 0)}
                ayuda="Piezas buenas del último proceso con estándar mayor a cero. Es una aproximación a piezas terminadas, sin sumar todas las etapas."
              />
              <Tarjeta
                titulo="Horas de producción"
                valor={horas(suma("real"))}
                ayuda="Tiempo efectivo de tareas confirmadas, distribuido por día y descontando pausas. No equivale a horas de asistencia."
              />
              <Tarjeta
                titulo="Cumplimiento del estándar"
                valor={pct(r.cumplimiento)}
                ayuda="Tiempo estándar actual para piezas buenas / tiempo efectivo comparable. 100 %: tiempo previsto; 80 %: se utilizó más tiempo. Solo tareas terminadas en el período."
              />
              <Tarjeta
                titulo="Scrap por operaciones"
                valor={pct(r.scrapPct)}
                ayuda="Rechazos / (buenas + rechazos) de las tareas terminadas. Al juntar procesos, mide operaciones, no piezas únicas rechazadas."
              />
              <Tarjeta
                titulo="Tiempo en pausas"
                valor={horas(suma("pausa_seg"))}
                ayuda="Pausas distribuidas por su fecha real, incluidas las abiertas hasta la consulta. No todas representan fallas de máquina."
              />
            </div>
            <details className="card ind-ayuda">
              <summary>Cómo leer estos indicadores</summary>
              <p>
                Las cantidades se asignan al día de finalización de cada tarea confirmada; la aplicación no registra cuántas piezas se
                hicieron antes de medianoche. Las horas sí se distribuyen entre los días que abarca la tarea.
              </p>
              <p>
                Los estándares son los actuales del artículo: no son un presupuesto histórico congelado. Cambiarlos modifica la comparación.
                Sin estándar o sin duración válida, la tarea queda fuera del cumplimiento.
              </p>
              <p>
                Las horas son horas-persona registradas y pueden superar 24 por día al trabajar varias personas. Producción incluye solo
                tareas confirmadas; pausas también incluye tareas abiertas. La columna apilada suma registros de actividad que pueden
                superponerse; no representa horas únicas de asistencia.
              </p>
              <p>
                Órdenes: primer cierre completo encontrado en el historial. No incluye finalizadas con pendientes ni inventa fechas de
                cierres anteriores a la auditoría.
              </p>
              <p>Mantenimiento corresponde a toda la planta: no tiene asociación a artículo ni proceso y no cambia con esos dos filtros.</p>
            </details>
          </details>
          {(numero(datos.finalizadas_sin_fecha) > 0 || numero(datos.sin_etapas) > 0) && (
            <p className="card">
              {numero(datos.finalizadas_sin_fecha) > 0 && (
                <>Hay {datos.finalizadas_sin_fecha} órdenes finalizadas sin fecha de cierre en el historial; no se asignan a un día. </>
              )}
              {numero(datos.sin_etapas) > 0 && (
                <>Hay {datos.sin_etapas} tareas sin último proceso identificable; no aportan a piezas en último proceso.</>
              )}
            </p>
          )}
          <details className="card">
            <summary>Ver detalle y comparación de tiempos</summary>
            <p>
              {r.comparables} de {r.tareas} tareas tienen estándar y duración válidos para comparar.
            </p>
            <p>
              Mantenimiento: {fmt(suma("mantenimientos"), 0)} intervenciones · {horas(suma("mantenimiento_seg"))}; correctivo:{" "}
              {horas(suma("correctivo_seg"))}.
            </p>
            <p>
              Pausas iniciadas: {fmt(suma("pausas"), 0)}. Relación pausas/producción confirmada:{" "}
              {suma("real") > 0 ? fmt(suma("pausa_seg") / suma("real")) + " h por cada h" : "No aplica"}. Es una relación de registros, no
              disponibilidad de máquina.
            </p>
            <label>
              Agrupar por
              <select
                value={modo}
                onChange={(e) => {
                  setModo(e.target.value);
                  setPagina(1);
                }}
              >
                <option value="proceso">Artículo y proceso</option>
                <option value="orden">Orden</option>
                <option value="articulo">Artículo</option>
                <option value="tarea">Tarea</option>
                <option value="usuario">Usuario</option>
              </select>
            </label>
            <p className="ind-nota">
              Comparación sobre tareas terminadas en el período; una orden puede estar representada parcialmente. Desvío positivo significa
              más tiempo que el estándar. Las horas comparables excluyen tareas sin estándar o sin duración válida.
            </p>
            <div className="ind-tabla">
              <table>
                <thead>
                  <tr>
                    <th>Grupo</th>
                    <th>Tareas</th>
                    <th>Horas reales totales</th>
                    <th>Horas reales comparables</th>
                    <th>Horas estándar</th>
                    <th>Cumplimiento</th>
                    <th>Desvío</th>
                    <th>Buenas/h</th>
                    <th>Scrap</th>
                  </tr>
                </thead>
                <tbody>
                  {grupos.slice((pagina - 1) * TAMANO_PAGINA_INDICADORES, pagina * TAMANO_PAGINA_INDICADORES).map((g) => (
                    <tr key={g.key}>
                      <td>{g.nombre}</td>
                      <td>{g.tareas}</td>
                      <td>{horas(g.real)}</td>
                      <td>{g.comparables ? horas(g.realComparable) : "No aplica"}</td>
                      <td>{g.comparables ? horas(g.std) : "No aplica"}</td>
                      <td>{pct(g.cumplimiento)}</td>
                      <td>{pct(g.desvio)}</td>
                      <td>{modo === "proceso" || modo === "tarea" ? fmt(g.porHora) : "Ver por proceso"}</td>
                      <td>{pct(g.scrapPct)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="ind-atajos">
              <button className="btn btn-ghost" disabled={pagina <= 1} onClick={() => setPagina((p) => p - 1)}>
                Anterior
              </button>
              <span>
                {pagina} / {paginas}
              </span>
              <button className="btn btn-ghost" disabled={pagina >= paginas} onClick={() => setPagina((p) => p + 1)}>
                Siguiente
              </button>
            </div>
          </details>
        </>
      )}
    </section>
  );
}
function Tarjeta({ titulo, valor, ayuda }) {
  return (
    <article className="card ind-tarjeta">
      <h2>{titulo}</h2>
      <strong>{valor}</strong>
      <details>
        <summary>¿Qué significa?</summary>
        <p>{ayuda}</p>
      </details>
    </article>
  );
}
