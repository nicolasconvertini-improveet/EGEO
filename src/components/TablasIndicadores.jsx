import React from "react";
import { fmt, horas } from "../lib/indicadoresFormato";
export default function TablasIndicadores({ datos }) {
  return (
    <>
      <h2>Producción por artículo</h2>
      <div
        className="ind-tabla"
        role="region"
        aria-label="Producción por artículo"
        tabIndex={0}
      >
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
              <tr key={r.articulo_id + "|" + i}>
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
      <div
        className="ind-tabla"
        role="region"
        aria-label="Horas por motivo"
        tabIndex={0}
      >
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
    </>
  );
}
