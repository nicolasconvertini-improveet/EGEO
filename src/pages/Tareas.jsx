import React, { useState, useMemo } from "react";
import { Boxes } from "lucide-react";
import { ACTS, actLabel } from "../lib/constants";
import { nf, fmtDT, fmtClock, isoDate, efficiency, effColor, findArt } from "../lib/format";

const FILTROS_VACIOS = {
  desde: "",
  hasta: "",
  actividad: "",
  operario: "",
  pedido: "",
};

export default function Tareas({ arts, tars, setDetail }) {
  const [f, setF] = useState(FILTROS_VACIOS);
  const [abierto, setAbierto] = useState(false);
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));

  const operarios = useMemo(() => [...new Set(tars.map((t) => t.operario))].sort(), [tars]);
  const pedidos = useMemo(() => [...new Set(tars.map((t) => t.pedidoCodigo))].sort(), [tars]);

  const lista = useMemo(
    () =>
      tars.filter((t) => {
        if (f.desde && isoDate(t.fin) < f.desde) return false;
        if (f.hasta && isoDate(t.fin) > f.hasta) return false;
        if (f.actividad && t.actividad !== f.actividad) return false;
        if (f.operario && t.operario !== f.operario) return false;
        if (f.pedido && t.pedidoCodigo !== f.pedido) return false;
        return true;
      }),
    [tars, f],
  );

  const activos = Object.values(f).filter(Boolean).length;
  const tot = lista.reduce((s, t) => s + t.ok, 0);

  return (
    <>
      <div className="filters">
        <div className="ftop">
          <span className="ftitle">Filtros{activos > 0 ? ` (${activos})` : ""}</span>
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
                <input type="date" value={f.desde} onChange={(e) => set("desde", e.target.value)} />
              </div>
              <div>
                <label>Hasta</label>
                <input type="date" value={f.hasta} onChange={(e) => set("hasta", e.target.value)} />
              </div>
            </div>
            <div className="fgrid" style={{ marginTop: 9 }}>
              <div>
                <label>Proceso</label>
                <select value={f.actividad} onChange={(e) => set("actividad", e.target.value)}>
                  <option value="">Todos</option>
                  {ACTS.map((a) => (
                    <option key={a.key} value={a.key}>
                      {a.label}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label>Usuario</label>
                <select value={f.operario} onChange={(e) => set("operario", e.target.value)}>
                  <option value="">Todos</option>
                  {operarios.map((o) => (
                    <option key={o} value={o}>
                      {o}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div style={{ marginTop: 9 }}>
              <label>Orden</label>
              <select value={f.pedido} onChange={(e) => set("pedido", e.target.value)}>
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
        {lista.length} tarea{lista.length === 1 ? "" : "s"} · {nf(tot)} piezas OK
      </div>

      {lista.map((t) => {
        const a = findArt(arts, t.articuloId);
        const e = efficiency(a, t.actividad, t.ok, t.realSec);
        return (
          <div className="rowitem" key={t.id} onClick={() => setDetail({ type: "ped", id: t.pedidoId })}>
            <div className="lead" style={{ background: effColor(e), color: "#fff" }}>
              {e == null ? "—" : Math.round(e)}
            </div>
            <div className="mid">
              <div className="t">
                {t.pedidoCodigo} · {actLabel(t.actividad)}
              </div>
              <div className="s mono">
                {fmtDT(t.fin)} · {nf(t.ok)} OK · {t.operario}
              </div>
              <div className="s">
                Total {fmtClock(t.totalSec)} · Pausas {fmtClock(t.pausaSec)} · Neto {fmtClock(t.realSec)}
              </div>
              {t.observaciones && <div className="s observacion">{t.observaciones}</div>}
            </div>
          </div>
        );
      })}
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Boxes size={22} />
          </div>
          {tars.length === 0 ? "Todavía no hay tareas registradas" : "Ninguna tarea coincide con los filtros"}
        </div>
      )}
    </>
  );
}
