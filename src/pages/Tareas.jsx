import React, { useState, useMemo, useEffect } from "react";
import { Boxes, Pencil, Trash2 } from "lucide-react";
import { ACTS, actLabel } from "../lib/constants";
import {
  nf,
  fmtDT,
  isoDate,
  efficiency,
  effColor,
  findArt,
} from "../lib/format";
import { fetchTareasAbiertas, adminEliminarTarea } from "../api";
import ConfirmDialog from "../components/ConfirmDialog";

const FILTROS_VACIOS = {
  desde: "",
  hasta: "",
  actividad: "",
  operario: "",
  pedido: "",
  estado: "", // "" = registradas · "en_curso" = abiertas o sin confirmar
};

export default function Tareas({
  arts,
  tars,
  setDetail,
  rol,
  perfil,
  prefiltro,
  notify,
  reloadTars,
  reloadPeds,
}) {
  // Si se llega desde el tablero, los filtros vienen precargados y visibles.
  const [f, setF] = useState(() => ({
    ...FILTROS_VACIOS,
    ...(prefiltro || {}),
  }));
  const [abierto, setAbierto] = useState(() => !!prefiltro);
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));
  const esOperario = rol === "operario";
  const esAdmin = rol === "admin";

  // Tareas en curso: se leen aparte (la lista principal sólo trae registradas).
  const [abiertas, setAbiertas] = useState([]);
  useEffect(() => {
    if (f.estado !== "en_curso") return;
    let vigente = true;
    fetchTareasAbiertas({ operarioId: esOperario ? perfil?.id : null })
      .then((l) => vigente && setAbiertas(l))
      .catch(
        () =>
          vigente && notify("No se pudieron cargar las tareas en curso", true),
      );
    return () => {
      vigente = false;
    };
  }, [f.estado, esOperario, perfil?.id, notify]);
  const fuente = f.estado === "en_curso" ? abiertas : tars;

  // Eliminar tarea (sólo administrador).
  const [aEliminar, setAEliminar] = useState(null);
  const [motivoBaja, setMotivoBaja] = useState("");
  const [busy, setBusy] = useState(false);
  const eliminar = async () => {
    setBusy(true);
    try {
      await adminEliminarTarea(aEliminar, motivoBaja.trim());
      await Promise.all([reloadTars(), reloadPeds()]);
      notify("Tarea eliminada");
      setAEliminar(null);
    } catch (e) {
      notify(e.message, true);
    } finally {
      setBusy(false);
    }
  };

  const operarios = useMemo(
    () => [...new Set(fuente.map((t) => t.operario))].sort(),
    [fuente],
  );
  const pedidos = useMemo(
    () => [...new Set(fuente.map((t) => t.pedidoCodigo))].sort(),
    [fuente],
  );

  const lista = useMemo(
    () =>
      fuente.filter((t) => {
        const dia = isoDate(t.fin || t.inicio);
        if (f.desde && dia < f.desde) return false;
        if (f.hasta && dia > f.hasta) return false;
        if (f.actividad && t.actividad !== f.actividad) return false;
        if (f.operario && t.operario !== f.operario) return false;
        if (f.pedido && t.pedidoCodigo !== f.pedido) return false;
        return true;
      }),
    [fuente, f],
  );

  const activos = Object.values(f).filter(Boolean).length;
  const tot = lista.reduce((s, t) => s + t.ok, 0);

  return (
    <>
      <div className="filters">
        <div className="ftop">
          <span className="ftitle">
            Filtros{activos > 0 ? ` (${activos})` : ""}
          </span>
          <div style={{ display: "flex", gap: 12 }}>
            {activos > 0 && (
              <button className="linkmini" onClick={() => setF(FILTROS_VACIOS)}>
                Limpiar
              </button>
            )}
            <button className="linkmini" onClick={() => setAbierto((v) => !v)}>
              {abierto ? "Ocultar" : "Mostrar"}
            </button>
          </div>
        </div>
        {abierto && (
          <>
            <div className="fgrid">
              <div>
                <label>Desde</label>
                <input
                  type="date"
                  value={f.desde}
                  onChange={(e) => set("desde", e.target.value)}
                />
              </div>
              <div>
                <label>Hasta</label>
                <input
                  type="date"
                  value={f.hasta}
                  onChange={(e) => set("hasta", e.target.value)}
                />
              </div>
            </div>
            <div className="fgrid" style={{ marginTop: 9 }}>
              <div>
                <label>Proceso</label>
                <select
                  value={f.actividad}
                  onChange={(e) => set("actividad", e.target.value)}
                >
                  <option value="">Todos</option>
                  {ACTS.map((a) => (
                    <option key={a.key} value={a.key}>
                      {a.label}
                    </option>
                  ))}
                </select>
              </div>
              {!esOperario && (
                <div>
                  <label>Usuario</label>
                  <select
                    value={f.operario}
                    onChange={(e) => set("operario", e.target.value)}
                  >
                    <option value="">Todos</option>
                    {operarios.map((o) => (
                      <option key={o} value={o}>
                        {o}
                      </option>
                    ))}
                  </select>
                </div>
              )}
            </div>
            <div style={{ marginTop: 9 }}>
              <label>Estado</label>
              <select
                value={f.estado}
                onChange={(e) => set("estado", e.target.value)}
              >
                <option value="">Registradas</option>
                <option value="en_curso">En curso / sin confirmar</option>
              </select>
            </div>
            <div style={{ marginTop: 9 }}>
              <label>Orden</label>
              <select
                value={f.pedido}
                onChange={(e) => set("pedido", e.target.value)}
              >
                <option value="">Todos</option>
                {pedidos.map((p) => (
                  <option key={p} value={p}>
                    {p}
                  </option>
                ))}
              </select>
            </div>
          </>
        )}
      </div>

      <div className="search-count">
        {lista.length} tarea{lista.length === 1 ? "" : "s"} · {nf(tot)} piezas
        OK
      </div>

      <div className="lista">
        {lista.map((t) => {
          const a = findArt(arts, t.articuloId);
          const e =
            t.realSec > 0 && t.stdSec > 0 ? (100 * t.stdSec) / t.realSec : null;
          return (
            <div
              className="rowitem"
              key={t.id}
              onClick={() => setDetail({ type: "ped", id: t.pedidoId })}
            >
              <div
                className="lead"
                style={{ background: effColor(e), color: "#fff" }}
              >
                {e == null ? "—" : Math.round(e)}
              </div>
              <div className="mid">
                <div className="t t-wrap">
                  {t.pedidoCodigo} · {actLabel(t.actividad)} ·{" "}
                  {t.articuloNombre}
                </div>
                <div className="s mono">
                  Inicio {fmtDT(t.inicio)} · Fin {fmtDT(t.fin)}
                </div>
                <div className="s mono">
                  OK {nf(t.ok)} · Falladas {nf(t.scrap)} · {t.operario}
                </div>
                {t.resultados?.length > 0 && (
                  <div className="s">
                    {t.resultados
                      .map(
                        (r) =>
                          `${r.codigo}: ${r.piezas_ok} OK / ${r.piezas_scrap} rechazo`,
                      )
                      .join(" · ")}
                  </div>
                )}
                {t.observaciones && (
                  <div className="s observacion">{t.observaciones}</div>
                )}
              </div>
              {esAdmin && t.confirmada && (
                <div
                  className="row-acciones"
                  onClick={(ev) => ev.stopPropagation()}
                >
                  <button
                    className="iconbtn"
                    title="Editar tarea"
                    aria-label="Editar tarea"
                    onClick={() => setDetail({ type: "tareaEdit", id: t.id })}
                  >
                    <Pencil size={15} />
                  </button>
                  <button
                    className="iconbtn danger"
                    title="Eliminar tarea"
                    aria-label="Eliminar tarea"
                    onClick={() => {
                      setMotivoBaja("");
                      setAEliminar(t);
                    }}
                  >
                    <Trash2 size={15} />
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Boxes size={22} />
          </div>
          {fuente.length === 0
            ? "Todavía no hay tareas registradas"
            : "Ninguna tarea coincide con los filtros"}
        </div>
      )}

      <ConfirmDialog
        abierto={!!aEliminar}
        titulo="¿Eliminar esta tarea?"
        textoConfirmar="Eliminar"
        peligro
        busy={busy}
        deshabilitado={motivoBaja.trim().length < 3}
        onCancelar={() => setAEliminar(null)}
        onConfirmar={eliminar}
      >
        {aEliminar && (
          <>
            <p>
              {aEliminar.pedidoCodigo} · {actLabel(aEliminar.actividad)} ·{" "}
              {aEliminar.operario}
              <br />
              {fmtDT(aEliminar.inicio)} → {fmtDT(aEliminar.fin)} ·{" "}
              {nf(aEliminar.ok)} OK
            </p>
            <p>
              Se borran también sus pausas y se recalcula el avance de la orden.
              No se puede deshacer.
            </p>
            <div className="field">
              <label htmlFor="motivo-baja">Motivo (obligatorio)</label>
              <input
                id="motivo-baja"
                value={motivoBaja}
                onChange={(e) => setMotivoBaja(e.target.value)}
                maxLength={500}
              />
            </div>
          </>
        )}
      </ConfirmDialog>
    </>
  );
}
