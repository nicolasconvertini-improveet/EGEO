import PendientesTrabajo from "../components/PendientesTrabajo";
import React, { useEffect, useMemo, useState } from "react";
import {
  LayoutDashboard,
  TrendingUp,
  History,
  ChevronDown,
  ChevronRight,
} from "lucide-react";
import { OBJETIVO, actLabel } from "../lib/constants";
import { fetchTareas, fetchPausas } from "../api";
import {
  nf,
  dayShort,
  fmtHora,
  fmtDT,
  effColor,
  isoDate,
  limitesDia,
  fmtMin,
  findArt,
  findPed,
  ESCALA_EFF,
} from "../lib/format";

const REFRESCO_MS = 60000; // cada 1 minuto

export default function Tablero({
  tars,
  peds,
  arts,
  enCurso,
  setDetail,
  rol,
  irA,
  reloadTars,
  reloadPeds,
  reloadEnCurso,
}) {
  const [actualizado, setActualizado] = useState(() => new Date());
  // null = en vivo (hoy, con refresco). "AAAA-MM-DD" = día histórico.
  const [fecha, setFecha] = useState(null);
  const [tarsFecha, setTarsFecha] = useState([]);
  const [cargandoFecha, setCargandoFecha] = useState(false);
  const [pausas, setPausas] = useState([]);
  const [abiertos, setAbiertos] = useState({}); // operario -> desplegado

  const hoy = new Date();
  const hoyISO = isoDate(hoy);
  const vivo = fecha == null;
  const fechaRef = fecha || hoyISO;

  // Refresco automático sólo en vivo, mientras la pantalla está abierta y visible.
  useEffect(() => {
    if (!vivo) return;
    const id = setInterval(() => {
      if (document.hidden) return;
      Promise.all([reloadTars(), reloadPeds(), reloadEnCurso()]).then(() =>
        setActualizado(new Date()),
      );
    }, REFRESCO_MS);
    return () => clearInterval(id);
  }, [vivo, reloadTars, reloadPeds, reloadEnCurso]);

  // Día histórico: traer las tareas de ese día y los 6 anteriores (para la evolución).
  useEffect(() => {
    if (vivo) return;
    let vigente = true;
    setCargandoFecha(true);
    fetchTareas({ ...limitesDia(fecha, 6), limit: 3000 })
      .then((l) => vigente && setTarsFecha(l))
      .catch(() => vigente && setTarsFecha([]))
      .finally(() => vigente && setCargandoFecha(false));
    return () => {
      vigente = false;
    };
  }, [vivo, fecha]);

  // Pausas del día mostrado (en vivo se vuelven a leer en cada refresco).
  useEffect(() => {
    let vigente = true;
    fetchPausas(limitesDia(fechaRef))
      .then((l) => vigente && setPausas(l))
      .catch(() => vigente && setPausas([]));
    return () => {
      vigente = false;
    };
  }, [fechaRef, actualizado]);

  const base = vivo ? tars : tarsFecha;
  const tDia = base.filter((t) => t.fin && isoDate(t.fin) === fechaRef);
  const a = agg(tDia);

  const pedidosEnCurso = peds.filter((p) => p.estado === "en_curso").length;

  // Productividad por operario + detalle por orden y proceso.
  const operarios = useMemo(() => {
    const porOp = {};
    tDia.forEach((t) => (porOp[t.operario] ||= []).push(t));
    return Object.entries(porOp)
      .map(([nombre, l]) => {
        const grupos = {};
        l.forEach((t) =>
          (grupos[t.pedidoId + "|" + t.actividad] ||= []).push(t),
        );
        const detalle = Object.values(grupos)
          .map((g) => ({
            pedidoId: g[0].pedidoId,
            pedidoCodigo: g[0].pedidoCodigo,
            articuloId: g[0].articuloId,
            articuloNombre: g[0].articuloNombre,
            actividad: g[0].actividad,
            inicio: g.reduce(
              (m, t) => (t.inicio < m ? t.inicio : m),
              g[0].inicio,
            ),
            fin: g.reduce((m, t) => (t.fin > m ? t.fin : m), g[0].fin),
            ...agg(g),
          }))
          .sort((x, y) => (x.inicio < y.inicio ? -1 : 1));
        return { nombre, ...agg(l), detalle };
      })
      .sort((x, y) => (y.prod ?? -1) - (x.prod ?? -1));
  }, [tDia]);
  const maxProdOp = Math.max(
    OBJETIVO,
    Math.min(200, ...operarios.map((o) => o.prod || 0)),
  );

  // Tiempo por tipo de parada.
  const paradas = useMemo(() => {
    const m = {};
    pausas.forEach((p) => {
      m[p.motivo] ||= { motivo: p.motivo, seg: 0, n: 0 };
      m[p.motivo].seg += p.seg;
      m[p.motivo].n += 1;
    });
    return Object.values(m).sort((x, y) => y.seg - x.seg);
  }, [pausas]);
  const totalParadas = paradas.reduce((s, p) => s + p.seg, 0);
  const maxParada = Math.max(1, ...paradas.map((p) => p.seg));

  const dias = [];
  const [fy, fm, fd] = fechaRef.split("-").map(Number);
  for (let i = 6; i >= 0; i--) dias.push(new Date(fy, fm - 1, fd - i));
  const evo = dias.map((d) => ({
    d,
    prod: agg(base.filter((t) => t.fin && isoDate(t.fin) === isoDate(d))).prod,
  }));
  // Escalas separadas: un día atípico de la semana no debe achicar la comparación del día.
  const maxComp = Math.max(OBJETIVO, a.prod || 0);
  // Tope de 200 %: un valor atípico llega arriba de todo pero no aplasta al resto.
  const maxEvo = Math.max(
    OBJETIVO,
    Math.min(200, Math.max(0, ...evo.map((e) => e.prod || 0))),
  );
  const scrapPct = a.ok + a.scrap > 0 ? (a.scrap / (a.ok + a.scrap)) * 100 : 0;
  const filtroDia = { desde: fechaRef, hasta: fechaRef };

  return (
    <>
      {rol === "admin" && (
        <button
          className="btn btn-primary"
          style={{ marginBottom: 18 }}
          onClick={() => setDetail({ type: "indicadores" })}
        >
          Ver indicadores
        </button>
      )}
      <PendientesTrabajo irA={irA} />
      <div className="sec-title" style={{ marginTop: 0 }}>
        Situación actual
      </div>
      <div className="kpis">
        <Kpi
          lab="Órdenes en curso"
          val={nf(pedidosEnCurso)}
          col="var(--ink)"
          onClick={() => irA("pedidos", { estado: "en_curso" })}
        />
        <Kpi
          lab="Tareas en curso"
          val={nf(enCurso)}
          col={enCurso > 0 ? "var(--good)" : "var(--ink2)"}
          onClick={() => irA("tareas", { estado: "en_curso" })}
        />
      </div>

      <div className="dash-note dash-fecha" style={{ marginTop: 18 }}>
        {vivo ? <TrendingUp size={16} /> : <History size={16} />}
        <span>
          {vivo ? (
            <>
              En vivo — <b>hoy {dayShort(hoy)}</b> · actualizado{" "}
              {fmtHora(actualizado)}
            </>
          ) : (
            <>
              Histórico — <b>{dayShort(dias[6])}</b>
            </>
          )}
        </span>
        <input
          type="date"
          aria-label="Fecha del tablero"
          value={fechaRef}
          max={hoyISO}
          onChange={(e) =>
            setFecha(
              !e.target.value || e.target.value === hoyISO
                ? null
                : e.target.value,
            )
          }
        />
        {!vivo && (
          <button className="linkmini" onClick={() => setFecha(null)}>
            Volver a en vivo
          </button>
        )}
      </div>

      {cargandoFecha && (
        <div className="center" style={{ minHeight: 120 }}>
          <div className="spinner" />
        </div>
      )}

      {!cargandoFecha && tDia.length === 0 && (
        <div className="empty">
          <div className="ic">
            <LayoutDashboard size={22} />
          </div>
          {vivo
            ? "Todavía no hay tareas registradas hoy"
            : `No hay tareas registradas el ${dayShort(dias[6])}`}
        </div>
      )}

      {!cargandoFecha && tDia.length > 0 && (
        <>
          <div className="kpis">
            <Kpi
              lab="Unidades procesadas"
              val={nf(a.ok)}
              col="var(--good)"
              onClick={() => irA("tareas", filtroDia)}
            />
            <Kpi
              lab="Productividad"
              val={a.prod == null ? "—" : Math.round(a.prod) + "%"}
              col={effColor(a.prod)}
              onClick={() => irA("tareas", filtroDia)}
            />
            <Kpi
              lab="Tiempo estimado"
              val={(a.std / 3600).toFixed(1) + " h"}
              col="var(--ink)"
            />
            <Kpi
              lab="Scrap"
              val={scrapPct.toFixed(1) + "%"}
              col="var(--warn)"
            />
          </div>

          <div className="sec-title" style={{ marginTop: 18 }}>
            Productividad real vs. objetivo
          </div>
          <div className="card">
            <div className="compare">
              <CBar
                label="Real"
                pct={a.prod || 0}
                max={maxComp}
                color={effColor(a.prod)}
              />
              <CBar
                label="Objetivo"
                pct={OBJETIVO}
                max={maxComp}
                color="var(--ink2)"
              />
            </div>
            <div style={{ fontSize: 12, color: "var(--ink2)", marginTop: 12 }}>
              {a.prod == null
                ? "Sin datos suficientes."
                : a.prod >= OBJETIVO
                  ? `Se superó el objetivo por ${Math.round(a.prod - OBJETIVO)} puntos.`
                  : `Faltaron ${Math.round(OBJETIVO - a.prod)} puntos para el objetivo.`}
            </div>
            <LeyendaEff />
          </div>

          <div className="sec-title" style={{ marginTop: 18 }}>
            Productividad por operario
          </div>
          <div className="card">
            {operarios.map((o) => {
              const abierto = !!abiertos[o.nombre];
              return (
                <div className="opbloque" key={o.nombre}>
                  <button
                    type="button"
                    className="opbar opbar-btn"
                    aria-expanded={abierto}
                    onClick={() =>
                      setAbiertos((s) => ({ ...s, [o.nombre]: !s[o.nombre] }))
                    }
                  >
                    <span className="nm">
                      {abierto ? (
                        <ChevronDown size={14} />
                      ) : (
                        <ChevronRight size={14} />
                      )}{" "}
                      {o.nombre}
                    </span>
                    <span className="tr">
                      <i
                        style={{
                          width:
                            Math.min(100, ((o.prod || 0) / maxProdOp) * 100) +
                            "%",
                          background: effColor(o.prod),
                        }}
                      />
                      <b
                        className="obj"
                        style={{ left: (OBJETIVO / maxProdOp) * 100 + "%" }}
                        title="Objetivo"
                      />
                    </span>
                    <span
                      className="qt mono"
                      style={{ color: effColor(o.prod) }}
                    >
                      {o.prod == null ? "—" : Math.round(o.prod) + "%"}
                    </span>
                  </button>
                  {abierto && (
                    <div className="opdet">
                      {o.detalle.map((g) => (
                        <TarjetaOrden
                          key={g.pedidoId + g.actividad}
                          g={g}
                          art={findArt(arts, g.articuloId)}
                          ped={findPed(peds, g.pedidoId)}
                          onAbrir={() =>
                            setDetail({ type: "ped", id: g.pedidoId })
                          }
                        />
                      ))}
                      <button
                        className="linkmini"
                        onClick={() =>
                          irA("tareas", { ...filtroDia, operario: o.nombre })
                        }
                      >
                        Ver tareas de {o.nombre} →
                      </button>
                    </div>
                  )}
                </div>
              );
            })}
            <LeyendaEff objetivo />
          </div>
        </>
      )}

      {!cargandoFecha && (
        <>
          <div className="sec-title" style={{ marginTop: 18 }}>
            Tiempo por tipo de parada
          </div>
          <div className="card">
            {paradas.length === 0 ? (
              <div style={{ fontSize: 12.5, color: "var(--ink2)" }}>
                Sin paradas registradas en el día.
              </div>
            ) : (
              <>
                {paradas.map((p) => (
                  <div className="opbar" key={p.motivo}>
                    <div className="nm" title={p.motivo}>
                      {p.motivo}
                    </div>
                    <div className="tr">
                      <i
                        style={{
                          width: (p.seg / maxParada) * 100 + "%",
                          background: "var(--ink2)",
                        }}
                      />
                    </div>
                    <div className="qt mono">{fmtMin(p.seg)}</div>
                  </div>
                ))}
                <div
                  style={{ fontSize: 12, color: "var(--ink2)", marginTop: 10 }}
                >
                  Total {fmtMin(totalParadas)} en{" "}
                  {paradas.reduce((s, p) => s + p.n, 0)} paradas
                  {vivo ? " · incluye paradas abiertas hasta ahora" : ""}.
                </div>
              </>
            )}
          </div>

          <div className="sec-title" style={{ marginTop: 18 }}>
            Evolución general (7 días hasta {dayShort(dias[6])})
          </div>
          <div className="card">
            <div className="evo">
              {evo.map((e, i) => (
                <div className="col" key={i}>
                  <div className="pv" style={{ color: effColor(e.prod) }}>
                    {e.prod == null ? "" : Math.round(e.prod)}
                  </div>
                  <div
                    className="bar"
                    style={{
                      height:
                        (e.prod ? Math.min(100, (e.prod / maxEvo) * 100) : 0) +
                        "%",
                      background: effColor(e.prod),
                      opacity: e.prod == null ? 0.15 : 1,
                    }}
                  />
                  <div className="d">{dayShort(e.d)}</div>
                </div>
              ))}
            </div>
            <div
              style={{
                fontSize: 11.5,
                color: "var(--ink2)",
                marginTop: 8,
                textAlign: "center",
              }}
            >
              Productividad diaria (%)
            </div>
            <LeyendaEff />
          </div>
        </>
      )}
    </>
  );
}

function agg(list) {
  const ok = list.reduce((s, t) => s + t.ok, 0);
  const scrap = list.reduce((s, t) => s + t.scrap, 0);
  const std = list.reduce((s, t) => s + (t.stdSec || 0), 0);
  const real = list.reduce((s, t) => s + (t.realSec || 0), 0);
  return { ok, scrap, std, real, prod: real > 0 ? (std / real) * 100 : null };
}

/* Leyenda de la escala de colores de productividad. */
function LeyendaEff({ objetivo = false }) {
  return (
    <div className="leyenda" aria-label="Referencia de colores">
      {ESCALA_EFF.map((x) => (
        <span key={x.label} title={x.desc}>
          <i style={{ background: x.color }} /> {x.label}
        </span>
      ))}
      <span>
        <i style={{ background: "var(--ink2)", opacity: 0.4 }} /> Sin datos
      </span>
      {objetivo && (
        <span>
          <i className="leyenda-obj" /> Objetivo {OBJETIVO} %
        </span>
      )}
    </div>
  );
}

/* Tarjeta de detalle de un operario: una orden + proceso en el día. */
function TarjetaOrden({ g, art, ped, onAbrir }) {
  const scrapPct = g.ok + g.scrap > 0 ? (g.scrap / (g.ok + g.scrap)) * 100 : 0;
  return (
    <div className="opdet-card">
      <button type="button" className="rowitem" onClick={onAbrir}>
        <div
          className="lead"
          style={{ background: effColor(g.prod), color: "#fff" }}
        >
          {g.prod == null ? "—" : Math.round(g.prod)}
        </div>
        <div className="mid">
          <div className="t t-wrap">
            {art?.codigo || "—"} · {actLabel(g.actividad)} · {g.articuloNombre}
          </div>
          <div className="s mono">
            Orden {g.pedidoCodigo} · Inicio {fmtDT(g.inicio)} · Fin{" "}
            {fmtDT(g.fin)}
          </div>
        </div>
      </button>
      <div className="kpis kpis-5">
        <Kpi
          lab="Cantidad pedida"
          val={ped ? nf(ped.cantidad) : "—"}
          col="var(--ink)"
        />
        <Kpi lab="Unidades procesadas" val={nf(g.ok)} col="var(--good)" />
        <Kpi
          lab="Productividad"
          val={g.prod == null ? "—" : Math.round(g.prod) + "%"}
          col={effColor(g.prod)}
        />
        <Kpi
          lab="Tiempo estimado"
          val={(g.std / 3600).toFixed(1) + " h"}
          col="var(--ink)"
        />
        <Kpi lab="Scrap" val={scrapPct.toFixed(1) + "%"} col="var(--warn)" />
      </div>
    </div>
  );
}

function CBar({ label, pct, max, color }) {
  return (
    <div className="cbar">
      <div className="top">
        <span>{label}</span>
        <span className="mono" style={{ color }}>
          {Math.round(pct)}%
        </span>
      </div>
      <div className="track">
        <i
          style={{
            width: Math.min(100, (pct / max) * 100) + "%",
            background: color,
          }}
        />
      </div>
    </div>
  );
}

function Kpi({ lab, val, col, onClick }) {
  const Tag = onClick ? "button" : "div";
  return (
    <Tag
      className={"kpi" + (onClick ? " kpi-link" : "")}
      onClick={onClick}
      type={onClick ? "button" : undefined}
    >
      <div className="tick" style={{ background: col }} />
      <div className="lab">{lab}</div>
      <div className="val mono" style={{ color: col }}>
        {val}
      </div>
    </Tag>
  );
}
