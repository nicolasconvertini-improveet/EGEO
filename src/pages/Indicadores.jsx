import React, { useEffect, useState } from "react";
import { supabase } from "../supabaseClient";
import { fmt, horas, rango, validarPeriodo } from "../lib/indicadoresFormato";
import { ACTS } from "../lib/constants";
import SelectorArticulosIndicadores from "../components/SelectorArticulosIndicadores";
import "../indicadores.css";
export default function Indicadores({ rol }) {
  const [form, setForm] = useState(() => ({
      ...rango("semana"),
      articulos: null,
      proceso: "",
      operario: "",
    })),
    [consulta, setConsulta] = useState(form),
    [datos, setDatos] = useState(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [selector, setSelector] = useState(false),
    [tick, setTick] = useState(0);
  useEffect(() => {
    if (rol !== "admin") return;
    const ac = new AbortController();
    setBusy(true);
    setError("");
    setDatos(null);
    supabase
      .rpc("indicadores_tablas", {
        p_desde: consulta.desde,
        p_hasta: consulta.hasta,
        p_articulos: consulta.articulos,
        p_proceso: consulta.proceso,
        p_operario: consulta.operario || null,
      })
      .abortSignal(ac.signal)
      .then(({ data, error }) => {
        if (ac.signal.aborted) return;
        if (error) throw error;
        if (
          !data ||
          data.desde !== consulta.desde ||
          data.hasta !== consulta.hasta ||
          !Array.isArray(data.produccion) ||
          !Array.isArray(data.tiempos) ||
          !Array.isArray(data.catalogo) ||
          !Number.isFinite(Number(data.total_segundos))
        )
          throw new Error("Respuesta de indicadores incompleta");
        setDatos(data);
      })
      .catch((e) => {
        if (!ac.signal.aborted) setError(e.message);
      })
      .finally(() => {
        if (!ac.signal.aborted) setBusy(false);
      });
    return () => ac.abort();
  }, [consulta, tick, rol]);
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  if (rol !== "admin")
    return <p role="alert">Acceso exclusivo para administradores.</p>;
  const descargar = async () => {
    const XLSX = await import("xlsx");
    const libro = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(
      libro,
      XLSX.utils.aoa_to_sheet([
        ["Código de pieza", "Descripción", "OK", "Scrap"],
        ...datos.produccion.map((r) => [
          r.codigo,
          r.descripcion,
          Number(r.ok),
          Number(r.scrap),
        ]),
      ]),
      "Producción",
    );
    XLSX.utils.book_append_sheet(
      libro,
      XLSX.utils.aoa_to_sheet([
        ["Motivo", "Horas"],
        ...datos.tiempos.map((r) => [r.motivo, Number(r.segundos) / 3600]),
        ["Total", Number(datos.total_segundos) / 3600],
      ]),
      "Tiempos",
    );
    XLSX.writeFile(libro, "indicadores.xlsx");
  };
  return (
    <section className="ind gestion">
      <form
        className="card ind-filtros"
        onSubmit={(e) => {
          e.preventDefault();
          const error = validarPeriodo(form.desde, form.hasta);
          setError(error);
          if (!error) {
            setConsulta({ ...form });
            setTick((n) => n + 1);
          }
        }}
      >
        <label>
          Desde
          <input
            required
            type="date"
            value={form.desde}
            onChange={(e) => set("desde", e.target.value)}
          />
        </label>
        <label>
          Hasta
          <input
            required
            type="date"
            value={form.hasta}
            onChange={(e) => set("hasta", e.target.value)}
          />
        </label>
        <label>
          Proceso
          <select
            value={form.proceso}
            onChange={(e) => set("proceso", e.target.value)}
          >
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
          <select
            value={form.operario}
            onChange={(e) => set("operario", e.target.value)}
          >
            <option value="">Todos</option>
            {datos?.usuarios.map((u) => (
              <option key={u.id} value={u.id}>
                {u.nombre}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          className="btn btn-ghost"
          disabled={!datos}
          onClick={() => setSelector(true)}
        >
          Artículos:{" "}
          {form.articulos === null
            ? "todos"
            : form.articulos.length + " seleccionados"}
        </button>
        <button className="btn btn-primary" disabled={busy}>
          Consultar
        </button>
      </form>
      {selector && (
        <SelectorArticulosIndicadores
          catalogo={datos?.catalogo || []}
          valor={form.articulos}
          onAplicar={(valor) => {
            set("articulos", valor);
            setSelector(false);
          }}
          onCerrar={() => setSelector(false)}
        />
      )}
      {error && <p role="alert">{error}</p>}
      {busy && <p role="status">Cargando indicadores…</p>}
      {datos && !busy && (
        <>
          <p>
            Período: {consulta.desde} al {consulta.hasta}. Las cantidades suman
            operaciones de los procesos seleccionados. El tiempo de una tarea de
            molde se cuenta una sola vez, incluso al filtrar por uno de sus
            artículos.
          </p>
          <h2>Producción por artículo</h2>
          <div className="ind-tabla">
            <table>
              <thead>
                <tr>
                  <th>Código de pieza</th>
                  <th>Descripción</th>
                  <th>Piezas OK</th>
                  <th>Scrap</th>
                </tr>
              </thead>
              <tbody>
                {datos.produccion.map((r, i) => (
                  <tr key={r.articulo_id + "|" + r.codigo + "|" + i}>
                    <td>{r.codigo}</td>
                    <td>{r.descripcion}</td>
                    <td>{fmt(r.ok, 0)}</td>
                    <td>{fmt(r.scrap, 0)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!datos.produccion.length && (
            <p>Sin producción confirmada para estos filtros.</p>
          )}
          <h2>Horas por motivo</h2>
          <div className="ind-tabla">
            <table>
              <thead>
                <tr>
                  <th>Motivo</th>
                  <th>Horas</th>
                </tr>
              </thead>
              <tbody>
                {datos.tiempos.map((r) => (
                  <tr key={r.motivo}>
                    <td>{r.motivo}</td>
                    <td>{horas(r.segundos)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <th>Total</th>
                  <th>{horas(datos.total_segundos)}</th>
                </tr>
              </tfoot>
            </table>
          </div>
          <p>
            Horas-persona registradas. Mantenimiento y molienda se contabilizan
            por fecha de resolución y usuario ejecutor; no dependen del filtro
            de artículo o proceso. El total se calcula antes del redondeo.
          </p>
          <button
            className="btn btn-ghost"
            onClick={() => descargar().catch((e) => setError(e.message))}
          >
            Descargar tablas
          </button>
        </>
      )}
    </section>
  );
}
