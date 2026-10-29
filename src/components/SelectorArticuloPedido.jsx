import React, { useState, useMemo } from "react";
import { ACTS } from "../lib/constants";
import { norm, nf } from "../lib/format";
export default function SelectorArticuloPedido({
  arts,
  artId,
  onChange,
  busy = false,
}) {
  const [busqueda, setBusqueda] = useState(""),
    [categoria, setCategoria] = useState(""),
    [limite, setLimite] = useState(20);
  const activos = useMemo(() => arts.filter((a) => a.activo), [arts]);
  const categorias = useMemo(
    () =>
      [...new Set(activos.map((a) => a.categoria).filter(Boolean))].sort(
        (a, b) => a.localeCompare(b, "es"),
      ),
    [activos],
  );
  const seleccionado = activos.find((a) => a.id === artId);
  const resultados = useMemo(() => {
    const consulta = norm(busqueda.trim());
    const palabras = consulta.split(/\s+/).filter(Boolean);
    return activos
      .filter((a) => {
        if (categoria && a.categoria !== categoria) return false;
        const texto = norm(`${a.codigo} ${a.nombre}`);
        return palabras.every((palabra) => texto.includes(palabra));
      })
      .sort((a, b) => {
        const exactoA = consulta && norm(a.codigo) === consulta ? 1 : 0;
        const exactoB = consulta && norm(b.codigo) === consulta ? 1 : 0;
        return (
          exactoB - exactoA ||
          a.nombre.localeCompare(b.nombre, "es") ||
          a.codigo.localeCompare(b.codigo, "es", { numeric: true })
        );
      });
  }, [activos, busqueda, categoria]);

  return (
    <fieldset className="art-picker" disabled={busy}>
      <legend>
        Artículo <span className="req">*</span>
      </legend>
      {activos.length === 0 ? (
        <div className="hint-err">
          No hay artículos activos. Activá o creá uno primero.
        </div>
      ) : seleccionado ? (
        <div className="art-picker-selected">
          <span className="art-picker-code">{seleccionado.codigo}</span>
          <span className="art-picker-name">{seleccionado.nombre}</span>
          <span className="art-picker-category">
            {seleccionado.categoria || "Sin categoría"}
          </span>
          <section
            aria-label="Tiempos estándar del artículo"
            style={{ marginTop: 10 }}
          >
            <div style={{ fontSize: 13, fontWeight: 600 }}>
              Tiempos estándar por pieza
            </div>
            <div className="stds">
              {ACTS.map((proceso) => {
                const segundos = Number(seleccionado.std?.[proceso.key]);
                const aplica = Number.isFinite(segundos) && segundos > 0;
                return (
                  <div className="std" key={proceso.key}>
                    <div className="l">{proceso.label}</div>
                    <div className="v">
                      {aplica ? (
                        <>
                          {nf(segundos)} <small>s/pieza</small>
                        </>
                      ) : (
                        "no aplica"
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          </section>
          <button
            type="button"
            className="btn btn-ghost"
            onClick={() => onChange("")}
          >
            Cambiar artículo
          </button>
        </div>
      ) : (
        <>
          <div className="field">
            <label htmlFor="art-busqueda">
              Buscar por código o descripción
            </label>
            <input
              id="art-busqueda"
              type="search"
              autoFocus
              autoComplete="off"
              placeholder="Ej: 1204, VD50 o válvula rosca"
              value={busqueda}
              onChange={(e) => {
                setBusqueda(e.target.value);
                setLimite(20);
              }}
            />
          </div>
          <div className="field">
            <label htmlFor="art-categoria">Categoría (opcional)</label>
            <select
              id="art-categoria"
              value={categoria}
              onChange={(e) => {
                setCategoria(e.target.value);
                setLimite(20);
              }}
            >
              <option value="">Todas las categorías</option>
              {categorias.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          </div>
          <p className="art-picker-status" role="status">
            {resultados.length === 0
              ? "No hay coincidencias. Probá otra búsqueda o categoría."
              : `Mostrando ${Math.min(limite, resultados.length)} de ${resultados.length} artículos. Seleccioná uno para continuar.`}
          </p>
          <ul className="art-picker-results" aria-label="Artículos encontrados">
            {resultados.slice(0, limite).map((a) => (
              <li key={a.id}>
                <button
                  type="button"
                  className="art-picker-option"
                  onClick={() => onChange(a.id)}
                >
                  <span className="art-picker-code">{a.codigo}</span>
                  <span className="art-picker-name">{a.nombre}</span>
                  <span className="art-picker-category">
                    {a.categoria || "Sin categoría"}
                  </span>
                </button>
              </li>
            ))}
          </ul>
          {resultados.length > limite && (
            <button
              type="button"
              className="btn btn-ghost"
              onClick={() => setLimite((n) => n + 20)}
            >
              Ver más resultados
            </button>
          )}
        </>
      )}
    </fieldset>
  );
}
