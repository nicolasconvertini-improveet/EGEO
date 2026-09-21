import React, { useState, useEffect, useCallback, useMemo, useRef } from "react";
import { Timer, Plus, Play, Square, Check, Lock, Pause } from "lucide-react";
import { fetchTareaActiva, iniciarTarea, finalizarTarea, confirmarTarea, pausarTarea, reanudarTarea, fetchEtapasPedido } from "../api";
import { ACTS, actLabel } from "../lib/constants";
import { nf, fmtClock, fmtDT, fmtHora, efficiency, effColor, findArt, findPed, norm } from "../lib/format";
import SearchBox from "../components/SearchBox";

const MOTIVOS_PAUSA = ["Logística", "Almuerzo/descanso", "Sanitario", "Acondicionamiento de máquina", "Otras"];

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
  const [observaciones, setObservaciones] = useState("");
  const [motivo, setMotivo] = useState("");
  const [ahora, setAhora] = useState(Date.now());
  const [errorCarga, setErrorCarga] = useState(false);
  const operacion = useRef(false);
  const lectura = useRef(0);

  useEffect(() => {
    if (!activa || activa.fin) return;
    const id = setInterval(() => setAhora(Date.now()), 1000);
    return () => clearInterval(id);
  }, [activa?.id, activa?.fin]);

  // El total continúa durante la pausa. No se acumulan ticks locales.
  const servidorAhora = activa?.servidorAhora ? new Date(activa.servidorAhora).getTime() + Math.max(0, ahora - activa.recibidoEn) : ahora;
  const totalSec = activa
    ? Math.max(0, Math.floor(((activa.fin ? new Date(activa.fin).getTime() : servidorAhora) - new Date(activa.inicio).getTime()) / 1000))
    : 0;
  const pausaSec =
    (activa?.pausaSec || 0) +
    (activa?.pausaId ? Math.max(0, Math.floor((servidorAhora - new Date(activa.servidorAhora).getTime()) / 1000)) : 0);

  const disponibles = useMemo(() => peds.filter((p) => p.estado !== "finalizado"), [peds]);
  const opciones = useMemo(() => {
    const nq = norm(qPed.trim());
    if (!nq) return disponibles;
    return disponibles.filter((p) => norm(p.codigo).includes(nq) || norm(p.articuloNombre).includes(nq));
  }, [disponibles, qPed]);

  const cargarActiva = useCallback(
    async (silenciosa = false) => {
      const solicitud = ++lectura.current;
      if (!silenciosa) setCargando(true);
      try {
        const tarea = await fetchTareaActiva();
        if (solicitud !== lectura.current) return;
        setActiva(tarea);
        setAhora(Date.now());
        setErrorCarga(false);
      } catch {
        if (solicitud !== lectura.current) return;
        setErrorCarga(true);
        if (!silenciosa) notify("No se pudo verificar la tarea. Reintentá antes de continuar", true);
      } finally {
        if (solicitud === lectura.current) setCargando(false);
      }
    },
    [notify],
  );

  useEffect(() => {
    cargarActiva();
  }, [cargarActiva]);

  useEffect(() => {
    const actualizar = () => {
      if (!operacion.current && document.visibilityState === "visible") cargarActiva(true);
    };
    const id = setInterval(actualizar, 15000);
    window.addEventListener("focus", actualizar);
    document.addEventListener("visibilitychange", actualizar);
    return () => {
      clearInterval(id);
      window.removeEventListener("focus", actualizar);
      document.removeEventListener("visibilitychange", actualizar);
      lectura.current += 1;
    };
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
  }, [pedId, activa, peds]);

  // Si otra sesión termina la tarea y abre otra, no reutilizar cantidades.
  useEffect(() => {
    setOk(0);
    setScrap(0);
    setObservaciones("");
    setMotivo("");
  }, [activa?.id]);

  const pedSel = findPed(peds, pedId);
  const artSel = findArt(arts, pedSel?.articuloId);

  const ejecutar = async (accion, mensaje) => {
    if (operacion.current) return;
    operacion.current = true;
    lectura.current += 1;
    setBusy(true);
    try {
      await accion();
      setMotivo("");
      await cargarActiva(true);
      await Promise.all([reloadPeds(), reloadTars(), reloadEnCurso()]);
      if (mensaje) notify(mensaje);
    } catch (e) {
      notify(e?.message || "No se pudo guardar. Verificá tu conexión", true);
      await cargarActiva(true);
    } finally {
      operacion.current = false;
      setBusy(false);
    }
  };

  const iniciar = () => pedId && ejecutar(() => iniciarTarea({ pedidoId: pedId, actividad: act }), "Tarea iniciada");
  const finalizar = () => ejecutar(() => finalizarTarea(activa));
  const pausar = () => motivo && ejecutar(() => pausarTarea(activa, motivo), "Tarea pausada");
  const reanudar = () => ejecutar(() => reanudarTarea(activa), "Tarea reanudada");
  const confirmar = () =>
    ejecutar(async () => {
      await confirmarTarea(activa, { ok, scrap, observaciones });
      setHecha({
        art: findArt(arts, activa.articuloId),
        act: activa.actividad,
        ok,
        scrap,
        realSec: activa.realSec,
      });
      setOk(0);
      setScrap(0);
      setObservaciones("");
    }, "Tarea registrada");

  if (cargando)
    return (
      <div className="center" style={{ minHeight: 240 }}>
        <div className="spinner" />
      </div>
    );

  if (errorCarga)
    return (
      <div className="card">
        <p>No se pudo actualizar la tarea. Reconectá y reintentá para continuar.</p>
        <button className="btn btn-primary" disabled={busy} onClick={() => cargarActiva()}>
          Reintentar
        </button>
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
            <MiniStat lab="Tiempo operativo" val={fmtClock(hecha.realSec)} />
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

  /* La tarea sigue reservada mientras trabaja o está pausada. */
  if (activa && !activa.fin) {
    return (
      <>
        <div className="banner">
          <span className="dotcalm" />
          <span>Tarea en curso desde las {fmtHora(activa.inicio)}</span>
          <strong className="mono" role="timer" aria-label="Tiempo total transcurrido">
            {fmtClock(totalSec)}
          </strong>
        </div>
        <div className="locked">
          <div className="lrow">
            <span className="k">Orden</span>
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
        <div className="card" style={{ marginTop: 14 }}>
          <div>
            Tiempo no operativo: <strong className="mono">{fmtClock(pausaSec)}</strong>
          </div>
          {activa.pausaId ? (
            <>
              <p>
                En pausa desde las {fmtHora(activa.pausaInicio)} · {activa.pausaMotivo}
              </p>
              <button className="btn btn-primary" disabled={busy} onClick={reanudar}>
                <Play size={16} /> Reanudar tarea
              </button>
            </>
          ) : (
            <>
              <div className="field" style={{ marginTop: 12 }}>
                <label htmlFor="motivo-pausa">Motivo de la pausa</label>
                <select id="motivo-pausa" value={motivo} disabled={busy} onChange={(e) => setMotivo(e.target.value)}>
                  <option value="">Seleccioná un motivo</option>
                  {MOTIVOS_PAUSA.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </div>
              <button className="btn btn-primary" disabled={busy || !motivo} onClick={pausar}>
                <Pause size={16} /> Pausar tarea
              </button>
            </>
          )}
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
            <span className="k">Orden</span>
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
            <span className="k">Tiempo operativo neto</span>
            <span className="v mono">{fmtClock(activa.realSec)}</span>
          </div>
          <div className="lrow">
            <span className="k">Tiempo total</span>
            <span className="v mono">{fmtClock(activa.totalSec)}</span>
          </div>
          <div className="lrow">
            <span className="k">Tiempo no operativo</span>
            <span className="v mono">{fmtClock(activa.pausaSec)}</span>
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

        <div className="field" style={{ marginTop: 16 }}>
          <label htmlFor="observaciones">Observaciones</label>
          <textarea
            id="observaciones"
            rows={4}
            maxLength={2000}
            value={observaciones}
            disabled={busy}
            onChange={(e) => setObservaciones(e.target.value)}
            placeholder="Ej.: apareció rebaba y se necesitó repasar las piezas"
          />
          <small>{observaciones.length}/2000 · Si no hubo producción, explicá el motivo.</small>
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

        <button
          className="btn btn-primary"
          style={{ marginTop: 16 }}
          disabled={busy || (ok === 0 && scrap === 0 && !observaciones.trim())}
          onClick={confirmar}
        >
          <Check size={18} strokeWidth={2.5} /> Registrar tarea
        </button>
        {ok === 0 && scrap === 0 && !observaciones.trim() && (
          <div
            style={{
              textAlign: "center",
              fontSize: 11.5,
              color: "var(--ink2)",
              marginTop: 10,
            }}
          >
            Cargá las cantidades o explicá en observaciones por qué no hubo producción.
          </div>
        )}
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
        No hay órdenes abiertas para registrar tareas
      </div>
    );

  return (
    <>
      <div className="field" style={{ marginTop: 2 }}>
        <label>Orden</label>
        <SearchBox value={qPed} onChange={setQPed} placeholder="Buscar orden por código o artículo…" />
        <select value={pedId} onChange={(e) => setPedId(e.target.value)}>
          {opciones.map((p) => (
            <option key={p.id} value={p.id}>
              {p.codigo} · {p.articuloNombre}
            </option>
          ))}
        </select>
        {opciones.length === 0 && <div className="hint-err">Ninguna orden coincide con la búsqueda.</div>}
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
        <div className="ctl-hint">Al iniciar, la orden y la actividad quedan fijas. El tiempo se guarda solo.</div>
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
        Avance de la orden · {actLabel(actividad)}
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
