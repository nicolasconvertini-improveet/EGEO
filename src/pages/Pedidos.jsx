import React, { useState, useEffect, useMemo } from "react";
import { ClipboardList, Boxes, Plus, Check, Pencil } from "lucide-react";
import { fetchEtapasPedido, editarCantidadPedido } from "../api";
import { ACTS, actLabel, rango } from "../lib/constants";
import {
  nf,
  fmtDT,
  fmtHora,
  fmtClock,
  efficiency,
  effColor,
  estadoLabel,
  estadoBadge,
  findArt,
  findPed,
  norm,
} from "../lib/format";
import SearchBox from "../components/SearchBox";
import Highlight from "../components/Highlight";
import EstadoPedido from "../components/EstadoPedido";

export default function Pedidos({ rol, peds, setDetail, prefiltro }) {
  const [q, setQ] = useState("");
  // Filtro de estado precargado al llegar desde el tablero (ej.: "en_curso").
  const [estado, setEstado] = useState(prefiltro?.estado || "");
  const canCreate = rango(rol) >= 1;
  const lista = useMemo(() => {
    const nq = norm(q.trim());
    const base = estado ? peds.filter((p) => p.estado === estado) : peds;
    if (!nq) return base;
    return base.filter(
      (p) =>
        norm(p.codigo).includes(nq) ||
        norm(p.articuloNombre).includes(nq) ||
        norm(p.articuloCodigo).includes(nq) ||
        norm(estadoLabel(p.estado)).includes(nq),
    );
  }, [peds, q, estado]);

  return (
    <>
      {canCreate && (
        <button
          className="btn btn-dark"
          style={{ marginBottom: 12 }}
          onClick={() => setDetail({ type: "pedNew" })}
        >
          <Plus size={18} strokeWidth={2.5} /> Nueva orden
        </button>
      )}

      <SearchBox
        value={q}
        onChange={setQ}
        placeholder="Buscar por código o artículo…"
      />
      {estado && (
        <div className="filtro-activo">
          Mostrando sólo: <b>{estadoLabel(estado)}</b>
          <button className="linkmini" onClick={() => setEstado("")}>
            Quitar filtro
          </button>
        </div>
      )}
      {(q || estado) && (
        <div className="search-count">
          {lista.length} de {peds.length} órdenes
        </div>
      )}

      <div className="lista">
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
                    <Highlight text={p.articuloNombre} query={q} /> ·{" "}
                    {nf(p.cantidad)} {p.moldeId ? "ciclos" : "u."} ·{" "}
                    {p.proceso ? actLabel(p.proceso) : "Histórica multietapa"}
                  </div>
                </div>
                <span className={"badge " + estadoBadge(p.estado)}>
                  {estadoLabel(p.estado)}
                </span>
              </div>
              <div className="prog">
                <i
                  style={{
                    width: pct + "%",
                    background:
                      p.estado === "finalizado" ? "var(--good)" : "var(--ink)",
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
                  {nf(p.okAcum)} / {nf(p.cantidad)}{" "}
                  {p.moldeId ? "ciclos equivalentes OK" : "completas"}
                </span>
                <span>{pct}%</span>
              </div>
            </div>
          );
        })}
      </div>
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <ClipboardList size={22} />
          </div>
          {peds.length === 0
            ? "No hay órdenes"
            : "Ninguna orden coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

export function PedidoDetalle({
  arts,
  peds,
  tars,
  detail,
  notify,
  rol,
  reloadPeds,
}) {
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
  }, [pedidoId, notify]);

  const p = findPed(peds, pedidoId);
  if (!p) return null;
  const a = findArt(arts, p.articuloId);
  const pct = Math.min(100, Math.round((p.okAcum / p.cantidad) * 100));
  const rel = tars.filter((t) => t.pedidoId === p.id);
  const etapaDe = (k) =>
    etapas?.find((e) => e.actividad === k) || { ok: 0, scrap: 0, tareas: 0 };

  return (
    <>
      <div className="card">
        <div style={{ display: "flex", justifyContent: "space-between" }}>
          <div>
            <div
              className="mono"
              style={{ fontSize: 12, color: "var(--ink2)" }}
            >
              {p.codigo}
            </div>
            <div style={{ fontSize: 18, fontWeight: 700, marginTop: 2 }}>
              {p.articuloNombre}
            </div>
          </div>
          <span className={"badge " + estadoBadge(p.estado)}>
            {estadoLabel(p.estado)}
          </span>
        </div>
        <div className="prog" style={{ marginTop: 14 }}>
          <i
            style={{
              width: pct + "%",
              background:
                p.estado === "finalizado" ? "var(--good)" : "var(--ink)",
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
            {nf(p.okAcum)} / {nf(p.cantidad)}{" "}
            {p.moldeId ? "ciclos equivalentes OK" : "completas"}
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
            {p.etapasCompletas} de {p.etapasReq}{" "}
            {p.moldeId ? "artículo" : "proceso"}
            {p.etapasReq === 1 ? "" : "s"} completa
            {p.etapasCompletas === 1 ? "" : "s"}
            {p.etapasCompletas < p.etapasReq &&
              (["finalizado", "finalizado_pendientes"].includes(p.estado)
                ? " · cerrada con etapas incompletas"
                : p.estado === "cancelado"
                  ? " · orden cancelada"
                  : " · quedan objetivos para completar la producción")}
          </div>
        )}
      </div>

      {p.moldeId && (
        <div className="card">
          <h3>Artículos del molde {p.configuracion?.codigo}</h3>
          {p.articulos.map((x) => (
            <p key={x.articulo_id}>
              {x.codigo} · {x.nombre} · {x.unidades_ciclo} u/ciclo · Objetivo{" "}
              {p.cantidad * x.unidades_ciclo} OK · {x.ok} OK / {x.scrap} rechazo
              registrados
            </p>
          ))}
        </div>
      )}
      {rango(rol) >= 2 && (
        <EditarCantidad
          pedido={p}
          articulo={a}
          etapas={etapas}
          notify={notify}
          reloadPeds={reloadPeds}
        />
      )}

      {/* La key incluye la cantidad: si el cambio recalculó el estado, el bloque se vuelve a leer. */}
      {rango(rol) >= 2 && (
        <EstadoPedido
          key={p.id + ":" + p.cantidad}
          pedidoId={p.id}
          notify={notify}
          reloadPeds={reloadPeds}
          puedeCambiar={rol === "admin"}
        />
      )}

      <div className="sec-title" style={{ marginTop: 18 }}>
        Totales del proceso
      </div>
      {etapas === null ? (
        <div className="card" style={{ textAlign: "center", padding: 24 }}>
          <div className="spinner" style={{ margin: "0 auto" }} />
        </div>
      ) : (
        <div className="card" style={{ padding: 12 }}>
          <div className="etapas">
            {ACTS.filter(
              (ac) => !p.moldeId && (!p.proceso || ac.key === p.proceso),
            ).map((ac) => {
              const e = etapaDe(ac.key);
              const requerida = p.proceso
                ? ac.key === p.proceso
                : (a?.std?.[ac.key] || 0) > 0;
              const lista = requerida && e.ok >= p.cantidad;
              const vacia = e.ok === 0 && e.scrap === 0;
              return (
                <div
                  className={
                    "etapa" + (vacia ? " cero" : "") + (lista ? " lista" : "")
                  }
                  key={ac.key}
                >
                  <div className="en">
                    {ac.label}
                    {!requerida && <span className="eno"> no aplica</span>}
                    {lista && <span className="eok-tick"> ✓</span>}
                  </div>
                  <div
                    className="eok mono"
                    style={{ color: e.ok > 0 ? "var(--good)" : "var(--ink2)" }}
                  >
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
        const e =
          t.realSec > 0 && t.stdSec > 0 ? (100 * t.stdSec) / t.realSec : null;
        return (
          <div className="rowitem" key={t.id} style={{ cursor: "default" }}>
            <div
              className="lead"
              style={{ background: effColor(e), color: "#fff" }}
            >
              {e == null ? "—" : Math.round(e)}
            </div>
            <div className="mid">
              <div className="t">{actLabel(t.actividad)}</div>
              <div className="s mono">
                {fmtDT(t.inicio)} → {fmtHora(t.fin)} · {nf(t.ok)} OK ·{" "}
                {t.operario}
              </div>
              <div className="s">
                Total {fmtClock(t.totalSec)} · Pausas {fmtClock(t.pausaSec)} ·
                Neto {fmtClock(t.realSec)}
              </div>
              {t.observaciones && (
                <div className="s observacion">{t.observaciones}</div>
              )}
            </div>
          </div>
        );
      })}
    </>
  );
}

function EditarCantidad({ pedido, articulo, etapas, notify, reloadPeds }) {
  const [abierto, setAbierto] = useState(false);
  const [valor, setValor] = useState(String(pedido.cantidad));
  const [busy, setBusy] = useState(false);

  // Mínimo orientativo: mayor cantidad OK entre los procesos que aplican.
  // La base de datos vuelve a validarlo al guardar.
  const aplican = ACTS.filter((ac) =>
    pedido.proceso
      ? ac.key === pedido.proceso
      : (articulo?.std?.[ac.key] || 0) > 0,
  ).map((ac) => ac.key);
  const okDe = (k) => Number(etapas?.find((e) => e.actividad === k)?.ok) || 0;
  const minimo = pedido.moldeId
    ? Math.max(
        0,
        ...pedido.articulos.map((a) =>
          Math.ceil(Number(a.ok || 0) / a.unidades_ciclo),
        ),
      )
    : aplican.length
      ? Math.max(0, ...aplican.map(okDe))
      : (etapas || []).reduce((s, e) => s + (Number(e.ok) || 0), 0);
  const n = Number(valor);
  const error =
    !valor || n <= 0
      ? "Ingresá una cantidad mayor que cero."
      : n < minimo
        ? `No puede ser menor a ${nf(minimo)} (ya fabricadas).`
        : "";

  const guardar = async () => {
    if (error || busy || n === pedido.cantidad) return;
    setBusy(true);
    try {
      const r = await editarCantidadPedido(pedido.id, n);
      await reloadPeds();
      notify(`Cantidad actualizada a ${nf(r.cantidad)}`);
      setAbierto(false);
    } catch (e) {
      notify(e.message, true);
    } finally {
      setBusy(false);
    }
  };

  if (!abierto)
    return (
      <button
        type="button"
        className="btn btn-ghost"
        style={{ marginTop: 12 }}
        onClick={() => {
          setValor(String(pedido.cantidad));
          setAbierto(true);
        }}
      >
        <Pencil size={16} /> Editar cantidad a fabricar
      </button>
    );

  return (
    <div className="card" style={{ marginTop: 12 }}>
      <div className="field" style={{ marginTop: 0 }}>
        <label htmlFor="editar-cantidad">
          {pedido.moldeId ? "Ciclos previstos" : "Cantidad a fabricar"}
        </label>
        <input
          id="editar-cantidad"
          inputMode="numeric"
          value={valor}
          disabled={busy}
          onChange={(e) => setValor(e.target.value.replace(/\D/g, ""))}
        />
        <small>
          Actual: {nf(pedido.cantidad)} u. · Mínimo permitido:{" "}
          {etapas == null ? "…" : `${nf(Math.max(1, minimo))} u.`}
        </small>
        {error && <div className="hint-err">{error}</div>}
      </div>
      <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
        <button
          type="button"
          className="btn btn-ghost"
          disabled={busy}
          onClick={() => setAbierto(false)}
        >
          Cancelar
        </button>
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy || !!error || etapas == null || n === pedido.cantidad}
          onClick={guardar}
        >
          <Check size={16} /> {busy ? "Guardando…" : "Guardar"}
        </button>
      </div>
    </div>
  );
}
