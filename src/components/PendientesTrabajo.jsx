import React, { useEffect, useState } from "react";
import { solicitudes } from "../lib/plantaApi";
export default function PendientesTrabajo({ irA }) {
  const [rows, setRows] = useState(null),
    [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    const cargar = () =>
      solicitudes()
        .then((r) => {
          if (live) {
            setRows(r.filter((s) => s.estado !== "resuelta"));
            setError("");
          }
        })
        .catch((e) => live && setError(e.message));
    cargar();
    const timer = setInterval(cargar, 60000);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, []);
  return (
    <article className="card">
      <h3>Trabajos pendientes</h3>
      {error ? (
        <p role="alert">{error}</p>
      ) : rows ? (
        <>
          <p>
            {rows.filter((s) => s.tipo === "mantenimiento").length}{" "}
            mantenimientos · {rows.filter((s) => s.tipo === "molienda").length}{" "}
            tareas de molienda
          </p>
          {rows.slice(0, 5).map((s) => (
            <p key={s.id}>
              {s.tipo === "molienda" ? "Molienda" : s.detalle} ·{" "}
              {s.estado.replace("_", " ")}
            </p>
          ))}
        </>
      ) : (
        <p>Cargando…</p>
      )}
      <button className="btn btn-ghost" onClick={() => irA("mantenimiento")}>
        Ver pendientes
      </button>
    </article>
  );
}
