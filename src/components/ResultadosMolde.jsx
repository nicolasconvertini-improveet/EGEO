import React from "react";
export default function ResultadosMolde({
  articulos,
  resultados,
  onChange,
  disabled = false,
}) {
  const set = (a, key, value) =>
    onChange(
      articulos.map((x) => {
        const r = resultados.find((r) => r.articulo_id === x.articulo_id) || {
          articulo_id: x.articulo_id,
          piezas_ok: 0,
          piezas_scrap: 0,
        };
        return x.articulo_id === a ? { ...r, [key]: Number(value) } : r;
      }),
    );
  return (
    <fieldset className="gestion resultados-molde" disabled={disabled}>
      <legend>Producción por artículo del molde</legend>
      <div className="gestion-lista">
        {articulos.map((a) => {
          const r =
            resultados.find((r) => r.articulo_id === a.articulo_id) || {};
          return (
            <div className="card" key={a.articulo_id}>
              <strong>
                {a.codigo} · {a.nombre}
              </strong>
              {a.unidades_ciclo && <p>{a.unidades_ciclo} unidades por ciclo</p>}
              <label>
                Piezas OK
                <input
                  aria-label={"OK " + a.codigo}
                  type="number"
                  min="0"
                  step="1"
                  required
                  value={r.piezas_ok ?? 0}
                  onChange={(e) =>
                    set(a.articulo_id, "piezas_ok", e.target.value)
                  }
                />
              </label>
              <label>
                Scrap / rechazo
                <input
                  aria-label={"Scrap " + a.codigo}
                  type="number"
                  min="0"
                  step="1"
                  required
                  value={r.piezas_scrap ?? 0}
                  onChange={(e) =>
                    set(a.articulo_id, "piezas_scrap", e.target.value)
                  }
                />
              </label>
            </div>
          );
        })}
      </div>
    </fieldset>
  );
}
