import React, { memo } from "react";
import { numero } from "../lib/indicadores";
import { fmt } from "../lib/indicadoresFormato";

function ColumnasApiladas({ titulo, filas, series, unidad, nota, decimales = 1 }) {
  const maximo = Math.max(1, ...filas.map((d) => series.reduce((s, k) => s + Math.max(0, numero(d[k.key])), 0)));
  const margen = Math.max(60, fmt(maximo, decimales).length * 8 + 16);
  const ancho = Math.max(320, filas.length * 55 + margen + 10),
    alto = 300,
    base = 245,
    altura = 200;
  const paso = (ancho - margen - 10) / Math.max(1, filas.length),
    bar = Math.min(34, paso - 12);
  return (
    <section className="card ind-grafico">
      <h2>{titulo}</h2>
      <p className="ind-nota">{nota}</p>
      <div className="ind-leyenda">
        {series.map((s) => (
          <span key={s.key}>
            <i style={{ background: s.color }} />
            {s.label}
          </span>
        ))}
      </div>
      <div
        className="ind-grafico-scroll"
        tabIndex={0}
        role="region"
        aria-label={titulo + "; desplazá horizontalmente para ver todos los días"}
      >
        <svg
          viewBox={"0 0 " + ancho + " " + alto}
          style={{ minWidth: ancho }}
          role="img"
          aria-label={titulo + ". Valores exactos en la tabla de datos debajo."}
        >
          <text x={8} y={18} fill="#536071" fontSize={12}>
            {unidad}
          </text>
          {[0, 1, 2, 3, 4].map((i) => {
            const v = (maximo * i) / 4,
              y = base - (altura * i) / 4;
            return (
              <g key={i}>
                <line x1={margen} x2={ancho - 8} y1={y} y2={y} stroke="#e2e6eb" />
                <text x={margen - 6} y={y + 4} textAnchor="end" fontSize={11} fill="#536071">
                  {fmt(v, decimales)}
                </text>
              </g>
            );
          })}
          {filas.map((d, i) => {
            let acumulado = 0;
            const x = margen + i * paso + (paso - bar) / 2;
            return (
              <g key={d.dia}>
                {series.map((s) => {
                  const v = Math.max(0, numero(d[s.key])),
                    h = (v / maximo) * altura;
                  acumulado += h;
                  return (
                    <rect key={s.key} x={x} y={base - acumulado} width={bar} height={h} fill={s.color}>
                      <title>{d.dia + " · " + s.label + ": " + fmt(v, decimales) + " " + unidad}</title>
                    </rect>
                  );
                })}
                <text x={x + bar / 2} y={base + 20} textAnchor="middle" fontSize={11} fill="#536071">
                  {d.dia.slice(8) + "/" + d.dia.slice(5, 7)}
                </text>
              </g>
            );
          })}
        </svg>
      </div>
      <details>
        <summary>Ver valores por día</summary>
        <div className="ind-tabla">
          <table>
            <thead>
              <tr>
                <th scope="col">Día</th>
                {series.map((s) => (
                  <th scope="col" key={s.key}>
                    {s.label} ({unidad})
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filas.map((d) => (
                <tr key={d.dia}>
                  <th scope="row">{d.dia}</th>
                  {series.map((s) => (
                    <td key={s.key}>{fmt(d[s.key], decimales)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </section>
  );
}

export default memo(ColumnasApiladas);
