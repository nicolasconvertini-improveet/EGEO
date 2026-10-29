import React, { useEffect, useState } from "react";
import { solicitudes } from "../lib/plantaApi";
import { tarjetasTrabajos } from "../lib/trabajos";
export function TarjetasTrabajos({ rows, irA }) {
  return (
    <section aria-label="Mantenimientos y moliendas por estado">
      <div className="sec-title">Mantenimientos y moliendas por estado</div>
      <div className="kpis trabajos-kpis">
        {tarjetasTrabajos(rows).map((t) => (
          <button
            key={t.tipo + "-" + t.estado}
            type="button"
            className="kpi kpi-link"
            onClick={() =>
              irA("mantenimiento", { tipo: t.tipo, estado: t.estado })
            }
            aria-label={`${t.tipo === "mantenimiento" ? "Mantenimiento" : "Molienda"} · ${t.label}: ${t.cantidad}`}
          >
            <div
              className="tick"
              style={{
                background:
                  t.tipo === "mantenimiento" ? "var(--ink)" : "var(--warn)",
              }}
            />
            <div className="lab">
              {t.tipo === "mantenimiento" ? "Mantenimiento" : "Molienda"} ·{" "}
              {t.label}
            </div>
            <div className="val mono">{t.cantidad}</div>
          </button>
        ))}
      </div>
    </section>
  );
}
export default function PendientesTrabajo({ irA }) {
  const [rows, setRows] = useState(null),
    [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    const cargar = () =>
      solicitudes()
        .then((r) => {
          if (live) {
            setRows(r);
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
  if (error) return <p role="alert">{error}</p>;
  return rows ? (
    <TarjetasTrabajos rows={rows} irA={irA} />
  ) : (
    <p role="status">Cargando mantenimientos y moliendas…</p>
  );
}
