import React from "react";
import { LayoutDashboard, TrendingUp } from "lucide-react";
import { OBJETIVO } from "../lib/constants";
import { nf, dayKey, dayShort, effColor } from "../lib/format";

export default function Tablero({ tars, peds, enCurso }) {
  const ayer = new Date();
  ayer.setDate(ayer.getDate() - 1);
  const ayerKey = dayKey(ayer);
  const tAyer = tars.filter((t) => t.fin && dayKey(t.fin) === ayerKey);
  const a = agg(tAyer);

  const pedidosEnCurso = peds.filter((p) => p.estado === "en_curso").length;

  const porOp = {};
  tAyer.forEach((t) => {
    (porOp[t.operario] ||= []).push(t);
  });
  const operarios = Object.entries(porOp)
    .map(([nombre, l]) => ({ nombre, ...agg(l) }))
    .sort((x, y) => y.ok - x.ok);
  const maxOk = Math.max(1, ...operarios.map((o) => o.ok));

  const dias = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(ayer);
    d.setDate(ayer.getDate() - i);
    dias.push(d);
  }
  const evo = dias.map((d) => ({
    d,
    prod: agg(tars.filter((t) => t.fin && dayKey(t.fin) === dayKey(d))).prod,
  }));
  const maxProd = Math.max(OBJETIVO, ...evo.map((e) => e.prod || 0), a.prod || 0);
  const scrapPct = a.ok + a.scrap > 0 ? (a.scrap / (a.ok + a.scrap)) * 100 : 0;

  return (
    <>
      <div className="sec-title" style={{ marginTop: 0 }}>
        Situación actual
      </div>
      <div className="kpis">
        <Kpi lab="Órdenes en curso" val={nf(pedidosEnCurso)} col="var(--ink)" />
        <Kpi lab="Tareas en curso" val={nf(enCurso)} col={enCurso > 0 ? "var(--good)" : "var(--ink2)"} />
      </div>

      <div className="dash-note" style={{ marginTop: 18 }}>
        <TrendingUp size={16} />
        <span>
          Datos a día vencido — <b>{dayShort(ayer)}</b> (día anterior)
        </span>
      </div>

      {tAyer.length === 0 && (
        <div className="empty">
          <div className="ic">
            <LayoutDashboard size={22} />
          </div>
          Sin producción registrada el día anterior
        </div>
      )}

      {tAyer.length > 0 && (
        <>
          <div className="kpis">
            <Kpi lab="Unidades procesadas" val={nf(a.ok)} col="var(--good)" />
            <Kpi lab="Productividad" val={a.prod == null ? "—" : Math.round(a.prod) + "%"} col={effColor(a.prod)} />
            <Kpi lab="Tiempo estimado" val={(a.std / 3600).toFixed(1) + " h"} col="var(--ink)" />
            <Kpi lab="Scrap" val={scrapPct.toFixed(1) + "%"} col="var(--warn)" />
          </div>

          <div className="sec-title" style={{ marginTop: 18 }}>
            Productividad real vs. objetivo
          </div>
          <div className="card">
            <div className="compare">
              <CBar label="Real" pct={a.prod || 0} max={maxProd} color={effColor(a.prod)} />
              <CBar label="Objetivo" pct={OBJETIVO} max={maxProd} color="var(--ink2)" />
            </div>
            <div style={{ fontSize: 12, color: "var(--ink2)", marginTop: 12 }}>
              {a.prod == null
                ? "Sin datos suficientes."
                : a.prod >= OBJETIVO
                  ? `Se superó el objetivo por ${Math.round(a.prod - OBJETIVO)} puntos.`
                  : `Faltaron ${Math.round(OBJETIVO - a.prod)} puntos para el objetivo.`}
            </div>
          </div>

          <div className="sec-title" style={{ marginTop: 18 }}>
            Producción por operario
          </div>
          <div className="card">
            {operarios.map((o) => (
              <div className="opbar" key={o.nombre}>
                <div className="nm">{o.nombre}</div>
                <div className="tr">
                  <i
                    style={{
                      width: (o.ok / maxOk) * 100 + "%",
                      background: effColor(o.prod),
                    }}
                  />
                </div>
                <div className="qt mono">{nf(o.ok)} u</div>
              </div>
            ))}
          </div>
        </>
      )}

      <div className="sec-title" style={{ marginTop: 18 }}>
        Evolución general (últimos 7 días)
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
                  height: (e.prod ? (e.prod / maxProd) * 100 : 0) + "%",
                  background: effColor(e.prod),
                  opacity: e.prod == null ? 0.15 : 1,
                }}
              />
              <div className="d">{String(new Date(e.d).getDate()).padStart(2, "0")}</div>
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
      </div>
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

function Kpi({ lab, val, col }) {
  return (
    <div className="kpi">
      <div className="tick" style={{ background: col }} />
      <div className="lab">{lab}</div>
      <div className="val mono" style={{ color: col }}>
        {val}
      </div>
    </div>
  );
}
