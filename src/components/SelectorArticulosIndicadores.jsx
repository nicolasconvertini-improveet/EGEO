import React, { useEffect, useMemo, useRef, useState } from "react";
import { indexarCatalogo, filtrarIndiceCatalogo, cambiarSeleccion } from "../lib/indicadores";

export default function SelectorArticulosIndicadores({ catalogo, valor, onAplicar, onCerrar }) {
  const dialogo = useRef(null);
  const buscador = useRef(null);
  const lista = useRef(null);
  const [seleccion, setSeleccion] = useState(() => (valor === null ? null : [...valor]));
  const [categoria, setCategoria] = useState("");
  const [busqueda, setBusqueda] = useState("");
  const [soloSeleccionados, setSoloSeleccionados] = useState(false);
  const [limite, setLimite] = useState(100);
  const elegidos = useMemo(() => new Set(seleccion === null ? catalogo.map((a) => a.id) : seleccion), [seleccion, catalogo]);
  const categorias = useMemo(
    () => [...new Set(catalogo.map((a) => a.categoria || "Sin categoría"))].sort((a, b) => a.localeCompare(b)),
    [catalogo],
  );
  const indice = useMemo(() => indexarCatalogo(catalogo), [catalogo]);
  const filtrados = useMemo(() => filtrarIndiceCatalogo(indice, categoria, busqueda), [indice, categoria, busqueda]);
  const visibles = useMemo(
    () => (soloSeleccionados ? filtrados.filter((a) => elegidos.has(a.id)) : filtrados),
    [filtrados, soloSeleccionados, elegidos],
  );
  const cambiar = (ids, agregar) => setSeleccion((actual) => cambiarSeleccion(actual, catalogo, ids, agregar));

  useEffect(() => {
    const nodo = dialogo.current;
    const focoAnterior = document.activeElement;
    const overflow = document.body.style.overflow;
    if (!nodo.open) nodo.showModal();
    document.body.style.overflow = "hidden";
    buscador.current?.focus();
    const mantenerFoco = (evento) => {
      if (evento.key !== "Tab") return;
      const controles = [
        ...dialogo.current.querySelectorAll("button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex='0']"),
      ].filter((elemento) => elemento.getClientRects().length > 0);
      const primero = controles[0];
      const ultimo = controles[controles.length - 1];
      if (!primero) return;
      if (evento.shiftKey && document.activeElement === primero) {
        evento.preventDefault();
        ultimo.focus();
      } else if (!evento.shiftKey && document.activeElement === ultimo) {
        evento.preventDefault();
        primero.focus();
      }
    };

    return () => {
      nodo.close();
      document.body.style.overflow = overflow;
      if (focoAnterior instanceof HTMLElement && focoAnterior.isConnected) focoAnterior.focus();
    };
  }, []);
  useEffect(() => {
    setLimite(100);
    if (lista.current) lista.current.scrollTop = 0;
  }, [categoria, busqueda, soloSeleccionados]);

  const mantenerFoco = (evento) => {
    if (evento.key !== "Tab") return;
    const controles = [
      ...dialogo.current.querySelectorAll("button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex='0']"),
    ].filter((elemento) => elemento.getClientRects().length > 0);
    const primero = controles[0];
    const ultimo = controles[controles.length - 1];
    if (!primero) return;
    if (evento.shiftKey && document.activeElement === primero) {
      evento.preventDefault();
      ultimo.focus();
    } else if (!evento.shiftKey && document.activeElement === ultimo) {
      evento.preventDefault();
      primero.focus();
    }
  };

  return (
    <dialog
      ref={dialogo}
      className="ind-modal-articulos"
      aria-labelledby="ind-selector-titulo"
      onKeyDown={mantenerFoco}
      onCancel={(e) => {
        e.preventDefault();
        onCerrar();
      }}
    >
      <div className="ind-modal-contenido">
        <header className="ind-modal-cabecera">
          <div>
            <h2 id="ind-selector-titulo">Seleccionar artículos</h2>
            <small role="status" aria-live="polite">
              {elegidos.size} seleccionados
            </small>
          </div>
          <button type="button" className="iconbtn" aria-label="Cerrar sin aplicar" onClick={onCerrar}>
            ×
          </button>
        </header>
        <div className="ind-modal-controles">
          <div className="ind-modal-busqueda">
            <label>
              Buscar
              <input
                ref={buscador}
                type="search"
                placeholder="Código o nombre"
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
              />
            </label>
            <label>
              Categoría
              <select value={categoria} onChange={(e) => setCategoria(e.target.value)}>
                <option value="">Todas</option>
                {categorias.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <label className="ind-modal-checkbox">
            <input type="checkbox" checked={soloSeleccionados} onChange={(e) => setSoloSeleccionados(e.target.checked)} />
            Ver solo seleccionados
          </label>
          <div className="ind-modal-acciones">
            <button
              type="button"
              className="btn btn-ghost"
              disabled={!filtrados.length}
              onClick={() =>
                cambiar(
                  filtrados.map((a) => a.id),
                  true,
                )
              }
            >
              Agregar todos los filtrados ({filtrados.length})
            </button>
            <button type="button" className="btn btn-ghost" disabled={!elegidos.size} onClick={() => setSeleccion([])}>
              Quitar todos
            </button>
          </div>
          <small>Buscar o cambiar de categoría conserva tu selección.</small>
        </div>
        <div className="ind-modal-lista" ref={lista} aria-label="Artículos disponibles">
          {visibles.slice(0, limite).map((a) => (
            <label className="ind-modal-articulo" key={a.id}>
              <input type="checkbox" checked={elegidos.has(a.id)} onChange={(e) => cambiar([a.id], e.target.checked)} />
              <span>
                <b>{a.codigo}</b>
                <span>{a.nombre}</span>
                <small>{a.categoria || "Sin categoría"}</small>
              </span>
            </label>
          ))}
          {!visibles.length && (
            <p className="ind-modal-vacio">
              {soloSeleccionados
                ? "No hay artículos seleccionados que coincidan con estos filtros."
                : "No hay artículos que coincidan con la búsqueda."}
            </p>
          )}
          {visibles.length > limite && (
            <button type="button" className="btn btn-ghost" onClick={() => setLimite((n) => n + 100)}>
              Mostrar más ({visibles.length - limite})
            </button>
          )}
        </div>
        <footer className="ind-modal-pie">
          <small>
            {!elegidos.size
              ? "Sin artículos: producción en cero; mantenimiento sigue global."
              : "Aplicá la selección y luego presioná Consultar / actualizar."}
          </small>
          <div>
            <button type="button" className="btn btn-ghost" onClick={onCerrar}>
              Cancelar
            </button>
            <button type="button" className="btn btn-primary" onClick={() => onAplicar(seleccion)}>
              Aplicar selección
            </button>
          </div>
        </footer>
      </div>
    </dialog>
  );
}
