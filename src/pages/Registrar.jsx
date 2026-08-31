import React, { useState, useEffect, useCallback, useMemo } from "react";
import { Timer, Plus, Play, Square, Check, Lock } from "lucide-react";
import { fetchTareaActiva, iniciarTarea, finalizarTarea, confirmarTarea, cancelarTarea, fetchEtapasPedido } from "../api";
import { ACTS, actLabel } from "../lib/constants";
import { nf, fmtClock, fmtDT, fmtHora, efficiency, effColor, findArt, findPed, norm } from "../lib/format";
import SearchBox from "../components/SearchBox";

export default function Registrar({ arts, peds, notify, reloadPeds, reloadTars, reloadEnCurso }) {
  const [cargando, setCargando] = useState(true);
  const [activa, setActiva] = useState(null);
  const [pedId, setPedId] = useState("");
  const [act, setAct] = useState("inyectado");
  const [ok, setOk] = useState(0);
  const [scrap, setScrap] = useState(0);
  const [busy, setBusy] = useState(false);
  const [hecha, setHecha] = useState(null);
  const [qPed, setQPed] = useState("");
  const [etapas, setEtapas] = useState(null);

  const disponibles = useMemo(() => peds.filter((p) => p.estado !== "finalizado"), [peds]);
  const opciones = useMemo(() => {
    const nq = norm(qPed.trim());
    if (!nq) return disponibles;
    return disponibles.filter((p) => norm(p.codigo).includes(nq) || norm(p.articuloNombre).includes(nq));
  }, [disponibles, qPed]);

  const cargarActiva = useCallback(async () => {
    setCargando(true);
    try {
      setActiva(await fetchTareaActiva());
    } catch {
      notify("No se pudo verificar si tenés una tarea abierta", true);
    } finally {
      setCargando(false);
    }
  }, [notify]);

  useEffect(() => {
    cargarActiva();
  }, [cargarActiva]);
  useEffect(() => {
    if (opciones.length === 0) return;
    if (!opciones.some((p) => p.id === pedId)) setPedId(opciones[0].id);
  }, [opciones, pedId]);

  // Avance por etapa del pedido en foco: el que se va a iniciar,
  // o el de la tarea en curso/por finalizar.
  useEffect(() => {
    const foco = activa ? activa.pedidoId : pedId;
    if (!foco) return;
    let vigente = true;
    setEtapas(null);
    fetchEtapasPedido(foco)
      .then((rows) => vigente && setEtapas(rows))
      .catch(() => vigente && setEtapas([]));
    return () => {
      vigente = false;
    };
  }, [pedId, activa]);

  const pedSel = findPed(peds, pedId);
  const artSel = findArt(arts, pedSel?.articuloId);

  const iniciar = async () => {
    if (!pedId) return;
    setBusy(true);
    try {
      await iniciarTarea({ pedidoId: pedId, actividad: act });
      await cargarActiva();
      await reloadEnCurso();
      notify("Tarea iniciada");
    } catch (e) {
      notify(e?.code === "23505" ? "Ya tenés una tarea abierta" : "No se pudo iniciar la tarea", true);
      await cargarActiva();
    } finally {
      setBusy(false);
    }
  };

  const finalizar = async () => {
    setBusy(true);
    try {
      await finalizarTarea(activa.id);
      await cargarActiva();
      await reloadEnCurso();
    } catch {
      notify("No se pudo finalizar la tarea", true);
    } finally {
      setBusy(false);
    }
  };

  const confirmar = async () => {
    setBusy(true);
    try {
      await confirmarTarea(activa.id, { ok, scrap });
      setHecha({
        art: findArt(arts, activa.articuloId),
        act: activa.actividad,
        ok,
        scrap,
        realSec: activa.realSec,
      });
      setActiva(null);
      setOk(0);
      setScrap(0);
      await Promise.all([reloadPeds(), reloadTars(), reloadEnCurso()]);
      notify("Tarea registrada");
    } catch {
      notify("No se pudo registrar la tarea", true);
    } finally {
      setBusy(false);
    }
  };

  const descartar = async () => {
    setBusy(true);
    try {
      await cancelarTarea(activa.id);
      setActiva(null);
      setOk(0);
      setScrap(0);
      await reloadEnCurso();
      notify("Tarea descartada");
    } catch {
      notify("No se pudo descartar", true);
    } finally {
      setBusy(false);
    }
  };

  if (cargando)
    return (
      <div className="center" style={{ minHeight: 240 }}>
        <div className="spinner" />
      </div>
    );

  /* resumen posterior */
  if (hecha) {
    const e = efficiency(hecha.art, hecha.act, hecha.ok, hecha.realSec);
    return (
      <div style={{ paddingTop: 4 }}>
        <div className="card">
          <Gauge value={e} />
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr 1fr 1fr",
              gap: 8,
              marginTop: 6,
            }}
          >
            <MiniStat lab="Piezas OK" val={nf(hecha.ok)} />
            <MiniStat lab="Scrap" val={nf(hecha.scrap)} />
            <MiniStat lab="Tiempo" val={fmtClock(hecha.realSec)} />
          </div>
          <div
            style={{
              textAlign: "center",
              fontSize: 12.5,
              color: "var(--ink2)",
              marginTop: 12,
              lineHeight: 1.5,
            }}
          >
            {hecha.art?.nombre} · {actLabel(hecha.act)}
            <br />
            Estándar {hecha.art?.std[hecha.act]}s/u — real {(hecha.realSec / (hecha.ok || 1)).toFixed(1)}s/u
          </div>
        </div>
        <button className="btn btn-primary" style={{ marginTop: 14 }} onClick={() => setHecha(null)}>
          <Plus size={18} strokeWidth={2.5} /> Registrar otra tarea
        </button>
      </div>
    );
  }

  /* tarea abierta: sólo finalizar */
  if (activa && !activa.fin) {
    return (
      <>
        <div className="banner">
          <span className="dotcalm" /> Tarea en curso desde las {fmtHora(activa.inicio)}
        </div>
        <div className="locked">
          <div className="lrow">
            <span className="k">Pedido</span>
            <span className="v">{activa.pedidoCodigo}</span>
          </div>
          <div className="lrow">
            <span className="k">Artículo</span>
            <span className="v">{activa.articuloNombre}</span>
          </div>
          <div className="lrow">
            <span className="k">Actividad</span>
            <span className="v">{actLabel(activa.actividad)}</span>
          </div>
          <div className="lrow">
            <span className="k">Inicio</span>
            <span className="v mono">{fmtDT(activa.inicio)}</span>
          </div>
        </div>
        <AvancePedido
          cantidad={findPed(peds, activa.pedidoId)?.cantidad}
          actividad={activa.actividad}
          aplica={(findArt(arts, activa.articuloId)?.std?.[activa.actividad] || 0) > 0}
          etapas={etapas}
        />
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 7,
            justifyContent: "center",
            fontSize: 12,
            color: "var(--ink2)",
            marginTop: 12,
          }}
        >
          <Lock size={13} /> Los datos quedan fijos hasta finalizar
        </div>
        <button className="btn btn-dark" style={{ marginTop: 14 }} disabled={busy} onClick={finalizar}>
          <Square size={15} fill="#fff" /> Finalizar tarea
        </button>
      </>
    );
  }

  /* finalizada: falta cargar piezas */
  if (activa && activa.fin) {
    const eff = efficiency(findArt(arts, activa.articuloId), activa.actividad, ok, activa.realSec);
    return (
      <>
        <div className="banner avisar">
          <Check size={15} /> Tarea finalizada · cargá las piezas producidas
        </div>
        <div className="locked">
          <div className="lrow">
            <span className="k">Pedido</span>
            <span className="v">{activa.pedidoCodigo}</span>
          </div>
          <div className="lrow">
            <span className="k">Actividad</span>
            <span className="v">{actLabel(activa.actividad)}</span>
          </div>
          <div className="lrow">
            <span className="k">Período</span>
            <span className="v mono">
              {fmtHora(activa.inicio)} → {fmtHora(activa.fin)}
            </span>
          </div>
          <div className="lrow">
            <span className="k">Duración</span>
            <span className="v mono">{fmtClock(activa.realSec)}</span>
          </div>
        </div>

        <div style={{ marginTop: 16 }}>
          <div className="sec-title" style={{ margin: "0 0 8px" }}>
            Piezas OK
          </div>
          <Counter value={ok} onChange={setOk} steps={[1, 10]} />
        </div>
        <div style={{ marginTop: 14 }}>
          <div className="sec-title" style={{ margin: "0 0 8px", color: "var(--warn)" }}>
            Scrap
          </div>
          <Counter value={scrap} onChange={setScrap} steps={[1]} warn />
        </div>

        {ok > 0 && (
          <div
            className="card"
            style={{
              marginTop: 14,
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
            }}
          >
            <div style={{ fontSize: 12.5, color: "var(--ink2)", fontWeight: 600 }}>Eficiencia estimada</div>
            <div className="mono" style={{ fontSize: 22, fontWeight: 700, color: effColor(eff) }}>
              {eff == null ? "—" : Math.round(eff) + "%"}
            </div>
          </div>
        )}

        <button className="btn btn-primary" style={{ marginTop: 16 }} disabled={busy || ok <= 0} onClick={confirmar}>
          <Check size={18} strokeWidth={2.5} /> Registrar tarea
        </button>
        {ok <= 0 && (
          <div
            style={{
              textAlign: "center",
              fontSize: 11.5,
              color: "var(--ink2)",
              marginTop: 10,
            }}
          >
            Cargá al menos una pieza OK para registrar.
          </div>
        )}
        <button className="linkmini" style={{ display: "block", margin: "16px auto 0" }} disabled={busy} onClick={descartar}>
          Descartar esta tarea
        </button>
      </>
    );
  }

  /* sin tarea activa */
  if (disponibles.length === 0)
    return (
      <div className="empty">
        <div className="ic">
          <Timer size={22} />
        </div>
        No hay pedidos abiertos para registrar tareas
      </div>
    );

  return (
    <>
      <div className="field" style={{ marginTop: 2 }}>
        <label>Pedido</label>
        <SearchBox value={qPed} onChange={setQPed} placeholder="Buscar pedido por código o artículo…" />
        <select value={pedId} onChange={(e) => setPedId(e.target.value)}>
          {opciones.map((p) => (
            <option key={p.id} value={p.id}>
              {p.codigo} · {p.articuloNombre}
            </option>
          ))}
        </select>
        {opciones.length === 0 && <div className="hint-err">Ningún pedido coincide con la búsqueda.</div>}
      </div>

      <div className="field">
        <label>Actividad</label>
        <div className="chips">
          {ACTS.map((ac) => (
            <button
              key={ac.key}
              className={"chip" + (act === ac.key ? " on" : "")}
              disabled={!artSel?.std[ac.key]}
              onClick={() => setAct(ac.key)}
            >
              {ac.label}
            </button>
          ))}
        </div>
      </div>

      <AvancePedido cantidad={pedSel?.cantidad} actividad={act} aplica={(artSel?.std?.[act] || 0) > 0} etapas={etapas} />

      <div className="card" style={{ marginTop: 14 }}>
        <div className="sec-title" style={{ margin: "0 0 10px" }}>
          Control de tarea
        </div>
        <div className="ctl-hint">Al iniciar, el pedido y la actividad quedan fijos. El tiempo se guarda solo.</div>
        <button className="btn btn-dark" style={{ marginTop: 12 }} disabled={busy || !pedId || !artSel?.std[act]} onClick={iniciar}>
          <Play size={16} fill="#fff" /> Iniciar tarea
        </button>
      </div>
    </>
  );
}

function polar(cx, cy, r, deg) {
  const rad = (deg * Math.PI) / 180;
  return { x: cx + r * Math.cos(rad), y: cy + r * Math.sin(rad) };
}

function arc(cx, cy, r, v0, v1, max) {
  const a0 = 180 + (v0 / max) * 180,
    a1 = 180 + (v1 / max) * 180;
  const p0 = polar(cx, cy, r, a0),
    p1 = polar(cx, cy, r, a1);
  return `M ${p0.x} ${p0.y} A ${r} ${r} 0 ${a1 - a0 > 180 ? 1 : 0} 1 ${p1.x} ${p1.y}`;
}

function Gauge({ value }) {
  const MAX = 130,
    cx = 100,
    cy = 100,
    r = 78;
  const v = value == null ? 0 : Math.max(0, Math.min(value, MAX));
  const needle = polar(cx, cy, r - 8, 180 + (v / MAX) * 180);
  const col = effColor(value);
  return (
    <div className="gauge-wrap">
      <svg viewBox="0 0 200 116" width="210" style={{ maxWidth: "100%" }}>
        <path d={arc(cx, cy, r, 0, 80, MAX)} stroke="var(--bad-bg)" strokeWidth="15" fill="none" strokeLinecap="round" />
        <path d={arc(cx, cy, r, 80, 95, MAX)} stroke="var(--warn-bg)" strokeWidth="15" fill="none" />
        <path d={arc(cx, cy, r, 95, 130, MAX)} stroke="var(--good-bg)" strokeWidth="15" fill="none" strokeLinecap="round" />
        {value != null && <path d={arc(cx, cy, r, 0, v, MAX)} stroke={col} strokeWidth="15" fill="none" strokeLinecap="round" />}
        <line x1={cx} y1={cy} x2={needle.x} y2={needle.y} stroke="var(--ink)" strokeWidth="3" strokeLinecap="round" />
        <circle cx={cx} cy={cy} r="6" fill="var(--ink)" />
      </svg>
      <div className="gauge-val mono" style={{ color: col }}>
        {value == null ? "—" : Math.round(value) + "%"}
      </div>
      <div className="gauge-lab">Eficiencia vs estándar</div>
    </div>
  );
}

function AvancePedido({ cantidad, actividad, aplica, etapas }) {
  const solicitada = cantidad ?? 0;
  const producida = etapas?.find((e) => e.actividad === actividad)?.ok ?? 0;
  const pendiente = Math.max(0, solicitada - producida);
  return (
    <div className="card" style={{ marginTop: 14 }}>
      <div className="sec-title" style={{ margin: "0 0 10px" }}>
        Avance del pedido · {actLabel(actividad)}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
        <MiniStat lab="Solicitado" val={`${nf(solicitada)} u.`} />
        <MiniStat lab="Pendiente" val={!aplica ? "No aplica" : etapas == null ? "…" : `${nf(pendiente)} u.`} />
      </div>
      {aplica && etapas != null && producida > 0 && (
        <div
          style={{
            textAlign: "center",
            fontSize: 11.5,
            color: "var(--ink2)",
            marginTop: 8,
          }}
        >
          Ya registradas {nf(producida)} u. en esta etapa
        </div>
      )}
    </div>
  );
}

function MiniStat({ lab, val }) {
  return (
    <div
      style={{
        border: "1px solid var(--line)",
        borderRadius: 10,
        padding: "9px 6px",
        textAlign: "center",
      }}
    >
      <div
        style={{
          fontSize: 10,
          color: "var(--ink2)",
          textTransform: "uppercase",
          letterSpacing: ".04em",
          fontWeight: 600,
        }}
      >
        {lab}
      </div>
      <div className="mono" style={{ fontWeight: 700, fontSize: 15, marginTop: 3 }}>
        {val}
      </div>
    </div>
  );
}

function Counter({ value, onChange, steps = [1], warn }) {
  const asc = [...steps].sort((a, b) => a - b);
  return (
    <div className={"counter" + (warn ? " warn" : "")}>
      {asc
        .slice()
        .reverse()
        .map((s) => (
          <button key={"m" + s} className="cbtn l" onClick={() => onChange(Math.max(0, value - s))}>
            −{s}
          </button>
        ))}
      <input
        className="cnum"
        inputMode="numeric"
        value={value}
        onChange={(e) => onChange(Number(e.target.value.replace(/\D/g, "")) || 0)}
        onFocus={(e) => e.target.select()}
      />
      {asc.map((s) => (
        <button key={"p" + s} className="cbtn r" onClick={() => onChange(value + s)}>
          +{s}
        </button>
      ))}
    </div>
  );
}
