import React, { useEffect, useRef, useState } from "react";
import { Download } from "lucide-react";
import { descargarTablaExcel } from "../lib/exportarExcel";

const TABLAS = [
  { nombre: "tarea_pausas", titulo: "Pausas de tareas", detalle: "Todos los motivos e intervalos, incluidas las pausas abiertas." },
  { nombre: "tareas", titulo: "Tareas", detalle: "Todo el historial, incluidas las tareas en curso y sin confirmar." },
  { nombre: "articulos", titulo: "Artículos", detalle: "Todo el maestro, incluidos los artículos inactivos." },
  { nombre: "pedidos", titulo: "Órdenes", detalle: "Todas las órdenes, cualquiera sea su estado." },
  {
    nombre: "perfiles",
    titulo: "Usuarios",
    detalle: "Todos los usuarios, incluidos los inactivos, con su nombre, rol y fecha de creación.",
  },
];

export default function Exportar({ rol }) {
  const [tablaActiva, setTablaActiva] = useState(null);
  const [estado, setEstado] = useState("");
  const [error, setError] = useState("");
  const [resultado, setResultado] = useState(null);
  const control = useRef(null);
  useEffect(() => () => control.current?.abort(), []);

  if (rol !== "admin") return <div className="empty">Acceso exclusivo para administradores.</div>;

  const descargar = async (tabla) => {
    if (control.current) return;
    const actual = new AbortController();
    control.current = actual;
    setTablaActiva(tabla);
    setError("");
    setResultado(null);
    setEstado("Preparando la descarga…");
    try {
      const res = await descargarTablaExcel(tabla, { signal: actual.signal, onEstado: setEstado });
      if (!actual.signal.aborted) setResultado(res);
    } catch (e) {
      if (!actual.signal.aborted) setError(e?.message || "No se pudo exportar. Volvé a intentarlo.");
    } finally {
      if (!actual.signal.aborted) {
        setTablaActiva(null);
        setEstado("");
      }
      if (control.current === actual) control.current = null;
    }
  };

  return (
    <>
      <p style={{ color: "var(--ink2)", marginTop: 0 }}>
        Descargá cada tabla completa en un Excel independiente, sin filtros de fecha, estado ni operario. Incluye todas sus columnas.
      </p>
      {TABLAS.map((tabla) => (
        <div className="card" key={tabla.nombre} style={{ marginBottom: 14 }}>
          <h2 style={{ fontSize: 17, margin: "0 0 6px" }}>{tabla.titulo}</h2>
          <div className="mono" style={{ fontSize: 12, color: "var(--ink2)" }}>
            {tabla.nombre}
          </div>
          <p style={{ fontSize: 13 }}>{tabla.detalle}</p>
          <button
            className="btn btn-primary"
            disabled={tablaActiva !== null}
            onClick={() => descargar(tabla.nombre)}
            aria-label={`Descargar ${tabla.nombre} en Excel`}
          >
            <Download size={17} />
            {tablaActiva === tabla.nombre ? "Preparando…" : "Descargar Excel"}
          </button>
        </div>
      ))}
      <div role="status" aria-live="polite" style={{ overflowWrap: "anywhere" }}>
        {estado && <p>{estado}</p>}
        {resultado && (
          <p>
            Archivo preparado: <strong>{resultado.nombre}</strong>
            <br />
            {resultado.filas.toLocaleString("es-AR")} registros. Revisá las descargas del navegador.
          </p>
        )}
      </div>
      {error && (
        <div role="alert" className="hint-err">
          {error}
          <br />
          No se generó un archivo parcial.
        </div>
      )}
    </>
  );
}
