import React, { useState, useEffect, useMemo } from "react";
import { ClipboardList, Boxes, Plus, Check } from "lucide-react";
import { createPedido, fetchEtapasPedido } from "../api";
import { ACTS, actLabel, rango } from "../lib/constants";
import { nf, fmtDT, fmtHora, fmtClock, efficiency, effColor, estadoLabel, estadoBadge, findArt, findPed, norm } from "../lib/format";
import SearchBox from "../components/SearchBox";
import Highlight from "../components/Highlight";

export default function Pedidos({ rol, peds, setDetail }) {
  const [q, setQ] = useState("");
  const canCreate = rango(rol) >= 2;
  const lista = useMemo(() => {
    const nq = norm(q.trim());
    if (!nq) return peds;
    return peds.filter(
      (p) =>
        norm(p.codigo).includes(nq) ||
        norm(p.articuloNombre).includes(nq) ||
        norm(p.articuloCodigo).includes(nq) ||
        norm(estadoLabel(p.estado)).includes(nq),
    );
  }, [peds, q]);

  return (
    <>
      {canCreate && (
        <button className="btn btn-dark" style={{ marginBottom: 12 }} onClick={() => setDetail({ type: "pedNew" })}>
          <Plus size={18} strokeWidth={2.5} /> Nueva orden
        </button>
      )}

      <SearchBox value={q} onChange={setQ} placeholder="Buscar por código o artículo…" />
      {q && (
        <div className="search-count">
          {lista.length} de {peds.length} órdenes
        </div>
      )}

      {lista.map((p) => {
        const pct = Math.min(100, Math.round((p.okAcum / p.cantidad) * 100));
        return (
          <div
            className="rowitem"
            key={p.id}
            style={{ flexDirection: "column", alignItems: "stretch" }}
            onClick={() => setDetail({ type: "ped", id: p.id })}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
              <div className="mid">
                <div className="t">
                  <Highlight text={p.codigo} query={q} />
                </div>
                <div className="s">
                  <Highlight text={p.articuloNombre} query={q} /> · {nf(p.cantidad)} u.
                </div>
              </div>
              <span className={"badge " + estadoBadge(p.estado)}>{estadoLabel(p.estado)}</span>
            </div>
            <div className="prog">
              <i
                style={{
                  width: pct + "%",
                  background: p.estado === "finalizado" ? "var(--good)" : "var(--ink)",
                }}
              />
            </div>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                fontSize: 11.5,
                color: "var(--ink2)",
                marginTop: 6,
              }}
              className="mono"
            >
              <span>
                {nf(p.okAcum)} / {nf(p.cantidad)} completas
              </span>
              <span>{pct}%</span>
            </div>
          </div>
        );
      })}
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <ClipboardList size={22} />
          </div>
          {peds.length === 0 ? "No hay órdenes" : "Ninguna orden coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

export function PedidoDetalle({ arts, peds, tars, detail, notify }) {
  const [etapas, setEtapas] = useState(null);
  const pedidoId = detail?.id;

  useEffect(() => {
    let vivo = true;
    if (!pedidoId) return;
    setEtapas(null);
    fetchEtapasPedido(pedidoId)
      .then((d) => {
        if (vivo) setEtapas(d);
      })
      .catch(() => {
        if (vivo) {
          setEtapas([]);
          notify("No se pudieron cargar las etapas", true);
        }
      });
    return () => {
      vivo = false;
    };
  }, [pedidoId, notify, peds]);

  const p = findPed(peds, pedidoId);
  if (!p) return null;

  const a = findArt(arts, p.articuloId);
  const pct = Math.min(100, Math.round((p.okAcum / p.cantidad) * 100));
  const rel = tars.filter((t) => t.pedidoId === p.id);
  const etapaDe = (k) => etapas?.find((e) => e.actividad === k) || { ok: 0, scrap: 0, tareas: 0 };

  return (
    <>
      <div className="card">
        <div style={{ display: "flex", justifyContent: "space-between" }}>
          <div>
            <div className="mono" style={{ fontSize: 12, color: "var(--ink2)" }}>
              {p.codigo}
            </div>
            <div style={{ fontSize: 18, fontWeight: 700, marginTop: 2 }}>{p.articuloNombre}</div>
          </div>
          <span className={"badge " + estadoBadge(p.estado)}>{estadoLabel(p.estado)}</span>
        </div>
        <div className="prog" style={{ marginTop: 14 }}>
          <i
            style={{
              width: pct + "%",
              background: p.estado === "finalizado" ? "var(--good)" : "var(--ink)",
            }}
          />
        </div>
        <div
          className="mono"
          style={{
            display: "flex",
            justifyContent: "space-between",
            fontSize: 12,
            color: "var(--ink2)",
            marginTop: 7,
          }}
        >
          <span>
            {nf(p.okAcum)} / {nf(p.cantidad)} completas
          </span>
          <span>Scrap {nf(p.scrapAcum)}</span>
        </div>
        {p.etapasReq > 0 && (
          <div
            style={{
              fontSize: 11.5,
              color: "var(--ink2)",
              marginTop: 9,
              borderTop: "1px solid var(--line2)",
              paddingTop: 9,
            }}
          >
            {p.etapasCompletas} de {p.etapasReq} etapa
            {p.etapasReq === 1 ? "" : "s"} completa
            {p.etapasCompletas === 1 ? "" : "s"}
            {p.etapasCompletas < p.etapasReq && " · falta terminar las demás para cerrar la orden"}
          </div>
        )}
      </div>

      <div className="sec-title" style={{ marginTop: 18 }}>
        Totales por etapa
      </div>
      {etapas === null ? (
        <div className="card" style={{ textAlign: "center", padding: 24 }}>
          <div className="spinner" style={{ margin: "0 auto" }} />
        </div>
      ) : (
        <div className="card" style={{ padding: 12 }}>
          <div className="etapas">
            {ACTS.map((ac) => {
              const e = etapaDe(ac.key);
              const requerida = (a?.std?.[ac.key] || 0) > 0;
              const lista = requerida && e.ok >= p.cantidad;
              const vacia = e.ok === 0 && e.scrap === 0;
              return (
                <div className={"etapa" + (vacia ? " cero" : "") + (lista ? " lista" : "")} key={ac.key}>
                  <div className="en">
                    {ac.label}
                    {!requerida && <span className="eno"> no aplica</span>}
                    {lista && <span className="eok-tick"> ✓</span>}
                  </div>
                  <div className="eok mono" style={{ color: e.ok > 0 ? "var(--good)" : "var(--ink2)" }}>
                    {nf(e.ok)}
                  </div>
                  <div className="esc mono">
                    Scrap {nf(e.scrap)} · {e.tareas} tarea
                    {e.tareas === 1 ? "" : "s"}
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}

      <div className="sec-title" style={{ marginTop: 18 }}>
        Tareas de la orden
      </div>
      {rel.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Boxes size={22} />
          </div>
          Sin tareas registradas
        </div>
      )}
      {rel.map((t) => {
        const e = efficiency(a, t.actividad, t.ok, t.realSec);
        return (
          <div className="rowitem" key={t.id} style={{ cursor: "default" }}>
            <div className="lead" style={{ background: effColor(e), color: "#fff" }}>
              {e == null ? "—" : Math.round(e)}
            </div>
            <div className="mid">
              <div className="t">{actLabel(t.actividad)}</div>
              <div className="s mono">
                {fmtDT(t.inicio)} → {fmtHora(t.fin)} · {nf(t.ok)} OK · {t.operario}
              </div>
              <div className="s">
                Total {fmtClock(t.totalSec)} · Pausas {fmtClock(t.pausaSec)} · Neto {fmtClock(t.realSec)}
              </div>
              {t.observaciones && <div className="s observacion">{t.observaciones}</div>}
            </div>
          </div>
        );
      })}
    </>
  );
}

export function PedidoForm({ arts, setDetail, notify, reloadPeds }) {
  const activos = arts.filter((a) => a.activo);
  const [codigo, setCodigo] = useState("");
  const [artId, setArtId] = useState(activos[0]?.id || "");
  const [cant, setCant] = useState("");
  const [busy, setBusy] = useState(false);
  const valid = codigo.trim() && artId && Number(cant) > 0;

  const save = async () => {
    setBusy(true);
    try {
      await createPedido({ codigo, articuloId: artId, cantidad: cant });
      await reloadPeds();
      notify("Orden creada");
      setDetail(null);
    } catch (e) {
      notify(e?.code === "23505" ? "Ese código de orden ya existe" : "No se pudo crear la orden", true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="field">
        <label>
          Código de orden <span className="req">*</span>
        </label>
        <input value={codigo} onChange={(e) => setCodigo(e.target.value)} placeholder="Ej: 20260617" />
      </div>
      <div className="field">
        <label>
          Artículo <span className="req">*</span>
        </label>
        {activos.length === 0 ? (
          <div className="hint-err">No hay artículos activos. Activá o creá uno primero.</div>
        ) : (
          <select value={artId} onChange={(e) => setArtId(e.target.value)}>
            {activos.map((a) => (
              <option key={a.id} value={a.id}>
                {a.codigo} · {a.nombre}
              </option>
            ))}
          </select>
        )}
      </div>
      <div className="field">
        <label>
          Cantidad a fabricar <span className="req">*</span>
        </label>
        <input value={cant} inputMode="numeric" placeholder="10000" onChange={(e) => setCant(e.target.value.replace(/\D/g, ""))} />
      </div>
      <button className="btn btn-primary" style={{ marginTop: 22 }} disabled={!valid || busy} onClick={save}>
        <Check size={18} strokeWidth={2.5} /> Crear orden
      </button>
    </>
  );
}
