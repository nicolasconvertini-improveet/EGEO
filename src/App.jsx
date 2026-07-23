import React, { useState, useEffect, useCallback, useMemo } from "react";
import {
  LayoutDashboard,
  Package,
  ClipboardList,
  Timer,
  Boxes,
  Plus,
  ChevronLeft,
  Play,
  Square,
  Check,
  LogOut,
  Circle,
  ArrowRight,
  Settings2,
  TrendingUp,
  Search,
  Lock,
  Users,
  UserPlus,
} from "lucide-react";
import { supabase } from "./supabaseClient";
import {
  fetchPerfil,
  fetchArticulos,
  saveArticulo,
  setArticuloActivo,
  fetchPedidos,
  createPedido,
  fetchTareas,
  fetchEtapasPedido,
  contarTareasEnCurso,
  fetchTareaActiva,
  iniciarTarea,
  finalizarTarea,
  confirmarTarea,
  cancelarTarea,
  fetchUsuarios,
  updateUsuario,
  crearUsuario,
} from "./api";

/* ============================================================
   Constantes y helpers
   ============================================================ */
const ACTS = [
  { key: "inyectado", label: "Inyectado" },
  { key: "rebabado", label: "Rebabado" },
  { key: "armado", label: "Armado" },
  { key: "embolsado", label: "Embolsado" },
];
const actLabel = (k) => ACTS.find((a) => a.key === k)?.label || k;

const ROLES = {
  admin: {
    full: "Administrador",
    tabs: [
      "tablero",
      "registrar",
      "pedidos",
      "tareas",
      "articulos",
      "usuarios",
    ],
  },
  supervisor: {
    full: "Supervisor",
    tabs: ["tablero", "registrar", "pedidos", "tareas"],
  },
  operario: { full: "Operario", tabs: ["registrar"] },
};
const rango = (r) => ({ admin: 3, supervisor: 2, operario: 1 })[r] || 0;

const OBJETIVO = 100;

const nf = (n) => (n ?? 0).toLocaleString("es-AR");
const fmtClock = (sec) => {
  sec = Math.max(0, Math.round(sec || 0));
  const h = Math.floor(sec / 3600),
    m = Math.floor((sec % 3600) / 60),
    s = sec % 60;
  const p = (x) => String(x).padStart(2, "0");
  return h > 0 ? `${p(h)}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`;
};
const fmtDT = (iso) => {
  if (!iso) return "—";
  const d = new Date(iso),
    p = (x) => String(x).padStart(2, "0");
  return `${p(d.getDate())}/${p(d.getMonth() + 1)} ${p(d.getHours())}:${p(d.getMinutes())}`;
};
const fmtHora = (iso) => {
  if (!iso) return "—";
  const d = new Date(iso),
    p = (x) => String(x).padStart(2, "0");
  return `${p(d.getHours())}:${p(d.getMinutes())}`;
};
const isoDate = (d) => {
  const x = new Date(d);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
};
const dayKey = (d) => {
  const x = new Date(d);
  return `${x.getFullYear()}-${x.getMonth()}-${x.getDate()}`;
};
const dayShort = (d) => {
  const x = new Date(d);
  return `${String(x.getDate()).padStart(2, "0")}/${String(x.getMonth() + 1).padStart(2, "0")}`;
};

function efficiency(art, actividad, ok, realSec) {
  if (!art || !ok || !realSec) return null;
  const std = art.std[actividad];
  if (!std) return null;
  return ((ok * std) / realSec) * 100;
}
function effColor(e) {
  if (e == null) return "var(--ink2)";
  if (e >= 95) return "var(--good)";
  if (e >= 80) return "var(--warn)";
  return "var(--bad)";
}
const estadoLabel = (e) =>
  ({ pendiente: "Pendiente", en_curso: "En curso", finalizado: "Finalizado" })[
    e
  ] || e;
const estadoBadge = (e) =>
  ({ pendiente: "b-pend", en_curso: "b-curso", finalizado: "b-fin" })[e] ||
  "b-pend";
const findArt = (arts, id) => arts.find((a) => a.id === id);
const findPed = (peds, id) => peds.find((p) => p.id === id);

const norm = (s) =>
  (s || "")
    .toString()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");

function Highlight({ text, query }) {
  const t = text || "";
  const q = (query || "").trim();
  if (!q) return <>{t}</>;
  const i = norm(t).indexOf(norm(q));
  if (i < 0) return <>{t}</>;
  return (
    <>
      {t.slice(0, i)}
      <mark>{t.slice(i, i + q.length)}</mark>
      {t.slice(i + q.length)}
    </>
  );
}

/* ============================================================
   Gauge
   ============================================================ */
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
        <path
          d={arc(cx, cy, r, 0, 80, MAX)}
          stroke="var(--bad-bg)"
          strokeWidth="15"
          fill="none"
          strokeLinecap="round"
        />
        <path
          d={arc(cx, cy, r, 80, 95, MAX)}
          stroke="var(--warn-bg)"
          strokeWidth="15"
          fill="none"
        />
        <path
          d={arc(cx, cy, r, 95, 130, MAX)}
          stroke="var(--good-bg)"
          strokeWidth="15"
          fill="none"
          strokeLinecap="round"
        />
        {value != null && (
          <path
            d={arc(cx, cy, r, 0, v, MAX)}
            stroke={col}
            strokeWidth="15"
            fill="none"
            strokeLinecap="round"
          />
        )}
        <line
          x1={cx}
          y1={cy}
          x2={needle.x}
          y2={needle.y}
          stroke="var(--ink)"
          strokeWidth="3"
          strokeLinecap="round"
        />
        <circle cx={cx} cy={cy} r="6" fill="var(--ink)" />
      </svg>
      <div className="gauge-val mono" style={{ color: col }}>
        {value == null ? "—" : Math.round(value) + "%"}
      </div>
      <div className="gauge-lab">Eficiencia vs estándar</div>
    </div>
  );
}

/* ============================================================
   App
   ============================================================ */
const Shell = ({ children }) => (
  <div className="app-root">
    <div className="app">{children}</div>
  </div>
);

export default function App() {
  const [session, setSession] = useState(null);
  const [perfil, setPerfil] = useState(null);
  const [booting, setBooting] = useState(true);
  const [tab, setTab] = useState("registrar");
  const [detail, setDetail] = useState(null);
  const [toast, setToast] = useState(null);

  const [arts, setArts] = useState([]);
  const [peds, setPeds] = useState([]);
  const [tars, setTars] = useState([]);
  const [enCurso, setEnCurso] = useState(0);
  const [loadingData, setLoadingData] = useState(false);

  const notify = useCallback((msg, err = false) => setToast({ msg, err }), []);
  useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(null), 2800);
    return () => clearTimeout(id);
  }, [toast]);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setBooting(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s);
      if (!s) {
        setPerfil(null);
        setArts([]);
        setPeds([]);
        setTars([]);
      }
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!session) return;
    fetchPerfil(session.user.id)
      .then((p) => {
        setPerfil(p);
        setTab(ROLES[p.rol]?.tabs[0] || "registrar");
      })
      .catch(() => notify("No se pudo cargar el perfil", true));
  }, [session, notify]);

  const reloadArts = useCallback(
    () =>
      fetchArticulos()
        .then(setArts)
        .catch(() => notify("Error al cargar artículos", true)),
    [notify],
  );
  const reloadPeds = useCallback(
    () =>
      fetchPedidos()
        .then(setPeds)
        .catch(() => notify("Error al cargar pedidos", true)),
    [notify],
  );
  const reloadTars = useCallback(
    () =>
      fetchTareas({ desdeDias: 60, limit: 500 })
        .then(setTars)
        .catch(() => notify("Error al cargar tareas", true)),
    [notify],
  );
  const reloadEnCurso = useCallback(
    () =>
      contarTareasEnCurso()
        .then(setEnCurso)
        .catch(() => {}),
    [],
  );

  useEffect(() => {
    if (!perfil || !perfil.activo) return;
    setLoadingData(true);
    Promise.all([
      reloadArts(),
      reloadPeds(),
      reloadTars(),
      reloadEnCurso(),
    ]).finally(() => setLoadingData(false));
  }, [perfil, reloadArts, reloadPeds, reloadTars, reloadEnCurso]);

  if (booting)
    return (
      <Shell>
        <div className="center">
          <div className="spinner" />
        </div>
      </Shell>
    );
  if (!session)
    return (
      <Shell>
        <Login />
      </Shell>
    );
  if (perfil && !perfil.activo)
    return (
      <Shell>
        <div className="center" style={{ padding: 30, textAlign: "center" }}>
          <div>Tu cuenta está inactiva. Contactá a un administrador.</div>
          <button
            className="btn btn-ghost"
            style={{ maxWidth: 200 }}
            onClick={() => supabase.auth.signOut()}
          >
            Salir
          </button>
        </div>
      </Shell>
    );
  if (!perfil)
    return (
      <Shell>
        <div className="center">
          <div className="spinner" />
        </div>
      </Shell>
    );

  const rol = perfil.rol;
  const tabs = ROLES[rol].tabs;
  const shared = {
    rol,
    perfil,
    arts,
    peds,
    tars,
    enCurso,
    notify,
    setDetail,
    reloadArts,
    reloadPeds,
    reloadTars,
    reloadEnCurso,
  };

  return (
    <Shell>
      <AppBar
        rol={rol}
        tab={tab}
        detail={detail}
        arts={arts}
        peds={peds}
        onBack={() => setDetail(null)}
      />
      <div className={"body" + (tabs.length === 1 ? " nonav" : "")}>
        {loadingData ? (
          <div className="center" style={{ minHeight: 260 }}>
            <div className="spinner" />
          </div>
        ) : (
          <Screen {...shared} tab={tab} detail={detail} />
        )}
      </div>

      {toast && (
        <div className={"toast" + (toast.err ? " err" : "")}>
          <span className="tk">
            {toast.err ? (
              <Circle size={13} color="#fff" />
            ) : (
              <Check size={13} color="#fff" strokeWidth={3} />
            )}
          </span>
          {toast.msg}
        </div>
      )}

      {tabs.length > 1 && (
        <nav className="nav">
          {tabs.map((t) => (
            <button
              key={t}
              className={tab === t && !detail ? "on" : ""}
              onClick={() => {
                setTab(t);
                setDetail(null);
              }}
            >
              <span className="ic">{tabIcon(t)}</span>
              {tabLabel(t)}
            </button>
          ))}
        </nav>
      )}
    </Shell>
  );
}

function tabIcon(t) {
  const s = 19;
  if (t === "tablero") return <LayoutDashboard size={s} />;
  if (t === "articulos") return <Package size={s} />;
  if (t === "pedidos") return <ClipboardList size={s} />;
  if (t === "tareas") return <Boxes size={s} />;
  if (t === "usuarios") return <Users size={s} />;
  return <Timer size={s} />;
}
const tabLabel = (t) =>
  ({
    tablero: "Tablero",
    articulos: "Artículos",
    pedidos: "Pedidos",
    tareas: "Tareas",
    registrar: "Registrar",
    usuarios: "Usuarios",
  })[t];

/* ---------- App bar ---------- */
function AppBar({ rol, tab, detail, arts, peds, onBack }) {
  let title = tabLabel(tab),
    sub = null,
    back = false;
  if (detail?.type === "art") {
    const a = findArt(arts, detail.id);
    title = a?.nombre || "Artículo";
    sub = a?.codigo;
    back = true;
  } else if (detail?.type === "artNew") {
    title = detail.edit ? "Editar artículo" : "Nuevo artículo";
    back = true;
  } else if (detail?.type === "ped") {
    const p = findPed(peds, detail.id);
    title = p?.codigo || "Pedido";
    sub = p?.articuloNombre;
    back = true;
  } else if (detail?.type === "pedNew") {
    title = "Nuevo pedido";
    back = true;
  } else if (detail?.type === "usrNew") {
    title = "Nuevo usuario";
    back = true;
  } else if (tab === "tablero") sub = "Desempeño de la operación";

  return (
    <div className="appbar">
      <div className="row">
        <div style={{ minWidth: 0 }}>
          {back && (
            <button className="linkback" onClick={onBack}>
              <ChevronLeft size={16} /> Volver
            </button>
          )}
          <h1
            style={{
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {title}
          </h1>
          {sub && <div className="sub">{sub}</div>}
        </div>
        <div
          style={{
            display: "flex",
            gap: 8,
            alignItems: "center",
            flex: "none",
          }}
        >
          <span className="chip-role">{ROLES[rol].full}</span>
          <button
            className="iconbtn"
            title="Salir"
            onClick={() => supabase.auth.signOut()}
          >
            <LogOut size={17} />
          </button>
        </div>
      </div>
      <div className="hazard" />
    </div>
  );
}

/* ---------- Login ---------- */
function Login() {
  const [mode, setMode] = useState("in");
  const [email, setEmail] = useState("");
  const [pass, setPass] = useState("");
  const [nombre, setNombre] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  const submit = async () => {
    setErr("");
    setBusy(true);
    try {
      if (mode === "in") {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password: pass,
        });
        if (error) throw error;
      } else {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password: pass,
          options: { data: { nombre: nombre.trim() } },
        });
        if (error) throw error;
        if (!data.session) {
          setErr(
            "Cuenta creada. Revisá tu correo para confirmarla y luego ingresá.",
          );
          setMode("in");
        }
      }
    } catch (e) {
      setErr(
        e?.message === "Invalid login credentials"
          ? "Usuario o contraseña incorrectos."
          : e?.message || "No se pudo continuar.",
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login">
      <img src="/logo.png" alt="Improveet" className="brand" />
      <h2>Productividad</h2>
      <p>Registro de tareas y desempeño de planta.</p>
      {err && <div className="lerr">{err}</div>}
      {mode === "up" && (
        <div className="lf">
          <input
            placeholder="Nombre y apellido"
            value={nombre}
            onChange={(e) => setNombre(e.target.value)}
          />
        </div>
      )}
      <div className="lf">
        <input
          placeholder="E-mail"
          type="email"
          autoCapitalize="none"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </div>
      <div className="lf">
        <input
          placeholder="Contraseña"
          type="password"
          value={pass}
          onChange={(e) => setPass(e.target.value)}
        />
      </div>
      <button
        className="btn btn-primary"
        style={{ marginTop: 8 }}
        disabled={busy || !email || !pass}
        onClick={submit}
      >
        {mode === "in" ? "Ingresar" : "Crear cuenta"}{" "}
        <ArrowRight size={17} strokeWidth={2.4} />
      </button>
      <div className="switch-mode">
        {mode === "in" ? (
          <>
            ¿No tenés cuenta?{" "}
            <button
              onClick={() => {
                setMode("up");
                setErr("");
              }}
            >
              Crear una
            </button>
          </>
        ) : (
          <>
            ¿Ya tenés cuenta?{" "}
            <button
              onClick={() => {
                setMode("in");
                setErr("");
              }}
            >
              Ingresar
            </button>
          </>
        )}
      </div>
    </div>
  );
}

/* ---------- Router ---------- */
function Screen(props) {
  const { tab, detail } = props;
  if (detail?.type === "art") return <ArticuloDetalle {...props} />;
  if (detail?.type === "artNew") return <ArticuloForm {...props} />;
  if (detail?.type === "ped") return <PedidoDetalle {...props} />;
  if (detail?.type === "pedNew") return <PedidoForm {...props} />;
  if (detail?.type === "usrNew") return <UsuarioForm {...props} />;
  if (tab === "tablero") return <Tablero {...props} />;
  if (tab === "articulos") return <Articulos {...props} />;
  if (tab === "pedidos") return <Pedidos {...props} />;
  if (tab === "tareas") return <Tareas {...props} />;
  if (tab === "registrar") return <Registrar {...props} />;
  if (tab === "usuarios") return <Usuarios {...props} />;
  return null;
}

/* ---------- Buscador ---------- */
function SearchBox({ value, onChange, placeholder }) {
  return (
    <div className="search">
      <Search size={17} color="#9AA2AB" />
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        autoComplete="off"
      />
      {value && (
        <button
          className="clear"
          onClick={() => onChange("")}
          aria-label="Limpiar"
        >
          ×
        </button>
      )}
    </div>
  );
}

/* ============================================================
   TABLERO
   ============================================================ */
function agg(list) {
  const ok = list.reduce((s, t) => s + t.ok, 0);
  const scrap = list.reduce((s, t) => s + t.scrap, 0);
  const std = list.reduce((s, t) => s + (t.stdSec || 0), 0);
  const real = list.reduce((s, t) => s + (t.realSec || 0), 0);
  return { ok, scrap, std, real, prod: real > 0 ? (std / real) * 100 : null };
}

function Tablero({ tars, peds, enCurso }) {
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
  const maxProd = Math.max(
    OBJETIVO,
    ...evo.map((e) => e.prod || 0),
    a.prod || 0,
  );
  const scrapPct = a.ok + a.scrap > 0 ? (a.scrap / (a.ok + a.scrap)) * 100 : 0;

  return (
    <>
      <div className="sec-title" style={{ marginTop: 0 }}>
        Situación actual
      </div>
      <div className="kpis">
        <Kpi lab="Pedidos en curso" val={nf(pedidosEnCurso)} col="var(--ink)" />
        <Kpi
          lab="Tareas en curso"
          val={nf(enCurso)}
          col={enCurso > 0 ? "var(--good)" : "var(--ink2)"}
        />
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
            <Kpi
              lab="Productividad"
              val={a.prod == null ? "—" : Math.round(a.prod) + "%"}
              col={effColor(a.prod)}
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
                max={maxProd}
                color={effColor(a.prod)}
              />
              <CBar
                label="Objetivo"
                pct={OBJETIVO}
                max={maxProd}
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
              <div className="d">
                {String(new Date(e.d).getDate()).padStart(2, "0")}
              </div>
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

/* ============================================================
   ARTÍCULOS
   ============================================================ */
function Articulos({ arts, setDetail }) {
  const [q, setQ] = useState("");
  const lista = useMemo(() => {
    const nq = norm(q.trim());
    if (!nq) return arts;
    return arts.filter(
      (a) =>
        norm(a.codigo).includes(nq) ||
        norm(a.nombre).includes(nq) ||
        norm(a.molde).includes(nq) ||
        norm(a.maquina).includes(nq) ||
        norm(a.material).includes(nq),
    );
  }, [arts, q]);

  return (
    <>
      <button
        className="btn btn-dark"
        style={{ marginBottom: 12 }}
        onClick={() => setDetail({ type: "artNew" })}
      >
        <Plus size={18} strokeWidth={2.5} /> Nuevo artículo
      </button>

      <SearchBox
        value={q}
        onChange={setQ}
        placeholder="Buscar por código, nombre, molde…"
      />
      {q && (
        <div className="search-count">
          {lista.length} de {arts.length} artículos
        </div>
      )}

      {lista.map((a) => (
        <div
          className="rowitem"
          key={a.id}
          onClick={() => setDetail({ type: "art", id: a.id })}
          style={{ opacity: a.activo ? 1 : 0.6 }}
        >
          <div className="lead">{a.codigo.slice(0, 3)}</div>
          <div className="mid">
            <div className="t">
              <Highlight text={a.nombre} query={q} />
            </div>
            <div className="s">
              <Highlight text={a.codigo} query={q} />
              {a.molde ? ` · Molde ${a.molde}` : ""}
              {a.maquina ? ` · ${a.maquina}` : ""}
            </div>
          </div>
          {!a.activo && <span className="badge b-off">Inactivo</span>}
          <ChevronLeft
            size={17}
            style={{ transform: "rotate(180deg)", color: "#C0C6CD" }}
          />
        </div>
      ))}
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Package size={22} />
          </div>
          {arts.length === 0
            ? "No hay artículos cargados"
            : "Ningún artículo coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

function ArticuloDetalle({ arts, detail, setDetail, notify, reloadArts }) {
  const a = findArt(arts, detail.id);
  if (!a) return null;
  const toggle = async () => {
    try {
      await setArticuloActivo(a.id, !a.activo);
      await reloadArts();
      notify(a.activo ? "Artículo inactivado" : "Artículo activado");
    } catch {
      notify("No se pudo actualizar", true);
    }
  };
  return (
    <>
      <div className="card">
        <div
          style={{
            display: "flex",
            justifyContent: "space-between",
            alignItems: "flex-start",
          }}
        >
          <div>
            <div
              style={{ fontSize: 12, color: "var(--ink2)", fontWeight: 600 }}
            >
              {a.codigo}
            </div>
            <div style={{ fontSize: 19, fontWeight: 700, marginTop: 2 }}>
              {a.nombre}
            </div>
          </div>
          <span className={"badge " + (a.activo ? "b-curso" : "b-off")}>
            {a.activo ? "Activo" : "Inactivo"}
          </span>
        </div>
        <div
          style={{
            display: "flex",
            gap: 18,
            marginTop: 14,
            fontSize: 13,
            color: "var(--ink2)",
            flexWrap: "wrap",
          }}
        >
          {a.molde && (
            <span>
              <b style={{ color: "var(--ink)" }}>Molde</b> {a.molde}
            </span>
          )}
          {a.maquina && (
            <span>
              <b style={{ color: "var(--ink)" }}>Máquina</b> {a.maquina}
            </span>
          )}
          {a.bocas ? (
            <span>
              <b style={{ color: "var(--ink)" }}>Bocas</b> {a.bocas}
            </span>
          ) : null}
        </div>
        {a.material && (
          <div style={{ marginTop: 6, fontSize: 13, color: "var(--ink2)" }}>
            <b style={{ color: "var(--ink)" }}>Material</b> {a.material}
          </div>
        )}
      </div>

      <div className="sec-title" style={{ marginTop: 18 }}>
        Tiempo estándar por unidad
      </div>
      <div className="card" style={{ padding: 12 }}>
        <div className="stds">
          {ACTS.map((ac) => (
            <div className="std" key={ac.key}>
              <div className="l">{ac.label}</div>
              <div className="v mono">
                {a.std[ac.key] ? a.std[ac.key] : "—"}
                {a.std[ac.key] ? <small> s/u</small> : ""}
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="toggle-row">
        <div>
          <div className="tl">
            {a.activo ? "Artículo activo" : "Artículo inactivo"}
          </div>
          <div className="ts">
            {a.activo
              ? "Disponible para nuevos pedidos"
              : "No aparece al crear pedidos"}
          </div>
        </div>
        <button
          className={"switch" + (a.activo ? " on" : "")}
          onClick={toggle}
          aria-label="Activar/inactivar"
        >
          <i />
        </button>
      </div>

      <button
        className="btn btn-dark"
        style={{ marginTop: 12 }}
        onClick={() => setDetail({ type: "artNew", edit: a.id })}
      >
        <Settings2 size={17} /> Editar
      </button>
    </>
  );
}

function ArticuloForm({ arts, detail, setDetail, notify, reloadArts }) {
  const edit = detail.edit ? findArt(arts, detail.edit) : null;
  const [f, setF] = useState(
    edit
      ? { ...edit, std: { ...edit.std } }
      : {
          codigo: "",
          nombre: "",
          molde: "",
          maquina: "",
          bocas: "",
          material: "",
          activo: true,
          std: { inyectado: "", rebabado: "", armado: "", embolsado: "" },
        },
  );
  const [busy, setBusy] = useState(false);
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));
  const setStd = (k, v) => setF((s) => ({ ...s, std: { ...s.std, [k]: v } }));
  const valid = f.codigo.trim() && f.nombre.trim();

  const save = async () => {
    setBusy(true);
    try {
      await saveArticulo(f, edit?.id);
      await reloadArts();
      notify(edit ? "Artículo actualizado" : "Artículo creado");
      setDetail(null);
    } catch (e) {
      notify(
        e?.code === "23505"
          ? "Ese código de artículo ya existe"
          : "No se pudo guardar",
        true,
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="field">
        <label>
          Código <span className="req">*</span>
        </label>
        <input
          value={f.codigo}
          onChange={(e) => set("codigo", e.target.value)}
          placeholder="PCH-C27"
        />
      </div>
      <div className="field">
        <label>
          Nombre <span className="req">*</span>
        </label>
        <input
          value={f.nombre}
          onChange={(e) => set("nombre", e.target.value)}
          placeholder="Percha P.Corta"
        />
      </div>
      <div style={{ display: "flex", gap: 10 }}>
        <div className="field" style={{ flex: 1 }}>
          <label>Molde</label>
          <input
            value={f.molde || ""}
            onChange={(e) => set("molde", e.target.value)}
          />
        </div>
        <div className="field" style={{ flex: 1 }}>
          <label>Máquina</label>
          <input
            value={f.maquina || ""}
            onChange={(e) => set("maquina", e.target.value)}
          />
        </div>
        <div className="field" style={{ flex: 1 }}>
          <label>Bocas</label>
          <input
            value={f.bocas || ""}
            inputMode="numeric"
            onChange={(e) => set("bocas", e.target.value)}
          />
        </div>
      </div>
      <div className="field">
        <label>Material</label>
        <input
          value={f.material || ""}
          onChange={(e) => set("material", e.target.value)}
          placeholder="PA7335 Verde"
        />
      </div>

      <div className="toggle-row">
        <div>
          <div className="tl">{f.activo ? "Activo" : "Inactivo"}</div>
          <div className="ts">
            {f.activo
              ? "Disponible para nuevos pedidos"
              : "No disponible para nuevos pedidos"}
          </div>
        </div>
        <button
          className={"switch" + (f.activo ? " on" : "")}
          onClick={() => set("activo", !f.activo)}
          aria-label="Activar/inactivar"
        >
          <i />
        </button>
      </div>

      <div className="sec-title" style={{ marginTop: 20 }}>
        Tiempo estándar por unidad (seg.)
      </div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
        {ACTS.map((ac) => (
          <div className="field" style={{ margin: 0 }} key={ac.key}>
            <label>{ac.label}</label>
            <input
              value={f.std[ac.key]}
              inputMode="decimal"
              placeholder="0"
              onChange={(e) => setStd(ac.key, e.target.value)}
            />
          </div>
        ))}
      </div>

      <button
        className="btn btn-primary"
        style={{ marginTop: 22 }}
        disabled={!valid || busy}
        onClick={save}
      >
        <Check size={18} strokeWidth={2.5} />{" "}
        {edit ? "Guardar cambios" : "Crear artículo"}
      </button>
    </>
  );
}

/* ============================================================
   PEDIDOS
   ============================================================ */
function Pedidos({ rol, peds, setDetail }) {
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
        <button
          className="btn btn-dark"
          style={{ marginBottom: 12 }}
          onClick={() => setDetail({ type: "pedNew" })}
        >
          <Plus size={18} strokeWidth={2.5} /> Nuevo pedido
        </button>
      )}

      <SearchBox
        value={q}
        onChange={setQ}
        placeholder="Buscar por código o artículo…"
      />
      {q && (
        <div className="search-count">
          {lista.length} de {peds.length} pedidos
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
                  <Highlight text={p.articuloNombre} query={q} /> ·{" "}
                  {nf(p.cantidad)} u.
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
                {nf(p.okAcum)} / {nf(p.cantidad)} OK
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
          {peds.length === 0
            ? "No hay pedidos"
            : "Ningún pedido coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

function PedidoDetalle({ arts, peds, tars, detail, notify }) {
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
            {nf(p.okAcum)} / {nf(p.cantidad)} OK
          </span>
          <span>Scrap {nf(p.scrapAcum)}</span>
        </div>
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
              const vacia = e.ok === 0 && e.scrap === 0;
              return (
                <div className={"etapa" + (vacia ? " cero" : "")} key={ac.key}>
                  <div className="en">{ac.label}</div>
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
        Tareas del pedido
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
            </div>
          </div>
        );
      })}
    </>
  );
}

function PedidoForm({ arts, setDetail, notify, reloadPeds }) {
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
      notify("Pedido creado");
      setDetail(null);
    } catch (e) {
      notify(
        e?.code === "23505"
          ? "Ese código de pedido ya existe"
          : "No se pudo crear el pedido",
        true,
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="field">
        <label>
          Código de pedido <span className="req">*</span>
        </label>
        <input
          value={codigo}
          onChange={(e) => setCodigo(e.target.value)}
          placeholder="Ej: 20260617"
        />
      </div>
      <div className="field">
        <label>
          Artículo <span className="req">*</span>
        </label>
        {activos.length === 0 ? (
          <div className="hint-err">
            No hay artículos activos. Activá o creá uno primero.
          </div>
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
        <input
          value={cant}
          inputMode="numeric"
          placeholder="10000"
          onChange={(e) => setCant(e.target.value.replace(/\D/g, ""))}
        />
      </div>
      <button
        className="btn btn-primary"
        style={{ marginTop: 22 }}
        disabled={!valid || busy}
        onClick={save}
      >
        <Check size={18} strokeWidth={2.5} /> Crear pedido
      </button>
    </>
  );
}

/* ============================================================
   TAREAS (con filtros)
   ============================================================ */
const FILTROS_VACIOS = {
  desde: "",
  hasta: "",
  actividad: "",
  operario: "",
  pedido: "",
};

function Tareas({ arts, tars, setDetail }) {
  const [f, setF] = useState(FILTROS_VACIOS);
  const [abierto, setAbierto] = useState(false);
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));

  const operarios = useMemo(
    () => [...new Set(tars.map((t) => t.operario))].sort(),
    [tars],
  );
  const pedidos = useMemo(
    () => [...new Set(tars.map((t) => t.pedidoCodigo))].sort(),
    [tars],
  );

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
            </div>
            <div style={{ marginTop: 9 }}>
              <label>Pedido</label>
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

      {lista.map((t) => {
        const a = findArt(arts, t.articuloId);
        const e = efficiency(a, t.actividad, t.ok, t.realSec);
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
              <div className="t">
                {t.pedidoCodigo} · {actLabel(t.actividad)}
              </div>
              <div className="s mono">
                {fmtDT(t.fin)} · {nf(t.ok)} OK · {t.operario}
              </div>
            </div>
          </div>
        );
      })}
      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Boxes size={22} />
          </div>
          {tars.length === 0
            ? "Todavía no hay tareas registradas"
            : "Ninguna tarea coincide con los filtros"}
        </div>
      )}
    </>
  );
}

/* ============================================================
   REGISTRAR TAREA
   nueva → abierta (sólo finalizar) → carga de piezas → resumen
   ============================================================ */
function Registrar({
  arts,
  peds,
  notify,
  reloadPeds,
  reloadTars,
  reloadEnCurso,
}) {
  const [cargando, setCargando] = useState(true);
  const [activa, setActiva] = useState(null);
  const [pedId, setPedId] = useState("");
  const [act, setAct] = useState("inyectado");
  const [ok, setOk] = useState(0);
  const [scrap, setScrap] = useState(0);
  const [busy, setBusy] = useState(false);
  const [hecha, setHecha] = useState(null);
  const [qPed, setQPed] = useState("");

  const disponibles = useMemo(
    () => peds.filter((p) => p.estado !== "finalizado"),
    [peds],
  );
  const opciones = useMemo(() => {
    const nq = norm(qPed.trim());
    if (!nq) return disponibles;
    return disponibles.filter(
      (p) => norm(p.codigo).includes(nq) || norm(p.articuloNombre).includes(nq),
    );
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
      notify(
        e?.code === "23505"
          ? "Ya tenés una tarea abierta"
          : "No se pudo iniciar la tarea",
        true,
      );
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
            Estándar {hecha.art?.std[hecha.act]}s/u — real{" "}
            {(hecha.realSec / (hecha.ok || 1)).toFixed(1)}s/u
          </div>
        </div>
        <button
          className="btn btn-primary"
          style={{ marginTop: 14 }}
          onClick={() => setHecha(null)}
        >
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
          <span className="dotcalm" /> Tarea en curso desde las{" "}
          {fmtHora(activa.inicio)}
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
        <button
          className="btn btn-dark"
          style={{ marginTop: 14 }}
          disabled={busy}
          onClick={finalizar}
        >
          <Square size={15} fill="#fff" /> Finalizar tarea
        </button>
      </>
    );
  }

  /* finalizada: falta cargar piezas */
  if (activa && activa.fin) {
    const eff = efficiency(
      findArt(arts, activa.articuloId),
      activa.actividad,
      ok,
      activa.realSec,
    );
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
          <div
            className="sec-title"
            style={{ margin: "0 0 8px", color: "var(--warn)" }}
          >
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
            <div
              style={{ fontSize: 12.5, color: "var(--ink2)", fontWeight: 600 }}
            >
              Eficiencia estimada
            </div>
            <div
              className="mono"
              style={{ fontSize: 22, fontWeight: 700, color: effColor(eff) }}
            >
              {eff == null ? "—" : Math.round(eff) + "%"}
            </div>
          </div>
        )}

        <button
          className="btn btn-primary"
          style={{ marginTop: 16 }}
          disabled={busy || ok <= 0}
          onClick={confirmar}
        >
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
        <button
          className="linkmini"
          style={{ display: "block", margin: "16px auto 0" }}
          disabled={busy}
          onClick={descartar}
        >
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
        <SearchBox
          value={qPed}
          onChange={setQPed}
          placeholder="Buscar pedido por código o artículo…"
        />
        <select value={pedId} onChange={(e) => setPedId(e.target.value)}>
          {opciones.map((p) => (
            <option key={p.id} value={p.id}>
              {p.codigo} · {p.articuloNombre}
            </option>
          ))}
        </select>
        {opciones.length === 0 && (
          <div className="hint-err">
            Ningún pedido coincide con la búsqueda.
          </div>
        )}
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

      <div className="card" style={{ marginTop: 14 }}>
        <div className="sec-title" style={{ margin: "0 0 10px" }}>
          Control de tarea
        </div>
        <div className="ctl-hint">
          Al iniciar, el pedido y la actividad quedan fijos. El tiempo se guarda
          solo.
        </div>
        <button
          className="btn btn-dark"
          style={{ marginTop: 12 }}
          disabled={busy || !pedId || !artSel?.std[act]}
          onClick={iniciar}
        >
          <Play size={16} fill="#fff" /> Iniciar tarea
        </button>
      </div>
    </>
  );
}

/* ============================================================
   USUARIOS (sólo administradores)
   ============================================================ */
const ROL_OPCIONES = [
  { key: "operario", label: "Operario", desc: "Registra tareas" },
  { key: "supervisor", label: "Supervisor", desc: "Además crea pedidos" },
  { key: "admin", label: "Administrador", desc: "Acceso total" },
];

function Usuarios({ perfil, notify, setDetail }) {
  const [usuarios, setUsuarios] = useState(null);
  const [q, setQ] = useState("");
  const [busyId, setBusyId] = useState(null);

  const cargar = useCallback(async () => {
    try {
      setUsuarios(await fetchUsuarios());
    } catch {
      setUsuarios([]);
      notify("No se pudieron cargar los usuarios", true);
    }
  }, [notify]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  const lista = useMemo(() => {
    if (!usuarios) return [];
    const nq = norm(q.trim());
    if (!nq) return usuarios;
    return usuarios.filter(
      (u) => norm(u.nombre).includes(nq) || norm(u.rol).includes(nq),
    );
  }, [usuarios, q]);

  const cambiarRol = async (u, rol) => {
    if (u.id === perfil.id) {
      notify("No podés cambiar tu propio rol", true);
      return;
    }
    setBusyId(u.id);
    try {
      await updateUsuario(u.id, { rol });
      await cargar();
      notify("Rol actualizado");
    } catch {
      notify("No se pudo actualizar el rol", true);
    } finally {
      setBusyId(null);
    }
  };

  const cambiarEstado = async (u) => {
    if (u.id === perfil.id) {
      notify("No podés desactivar tu propia cuenta", true);
      return;
    }
    setBusyId(u.id);
    try {
      await updateUsuario(u.id, { activo: !u.activo });
      await cargar();
      notify(u.activo ? "Usuario desactivado" : "Usuario activado");
    } catch {
      notify("No se pudo actualizar", true);
    } finally {
      setBusyId(null);
    }
  };

  if (usuarios === null)
    return (
      <div className="center" style={{ minHeight: 240 }}>
        <div className="spinner" />
      </div>
    );

  return (
    <>
      <button
        className="btn btn-dark"
        style={{ marginBottom: 12 }}
        onClick={() => setDetail({ type: "usrNew" })}
      >
        <UserPlus size={18} strokeWidth={2.4} /> Nuevo usuario
      </button>

      <SearchBox
        value={q}
        onChange={setQ}
        placeholder="Buscar por nombre o rol…"
      />
      {q && (
        <div className="search-count">
          {lista.length} de {usuarios.length} usuarios
        </div>
      )}

      {lista.map((u) => (
        <div
          className="card usercard"
          key={u.id}
          style={{ opacity: u.activo ? 1 : 0.62 }}
        >
          <div className="uhead">
            <div className="uav">
              {(u.nombre || "?").slice(0, 2).toUpperCase()}
            </div>
            <div className="umid">
              <div className="un">
                <Highlight text={u.nombre || "(sin nombre)"} query={q} />
                {u.id === perfil.id && <span className="uyou">vos</span>}
              </div>
              <div className="us">
                {ROL_OPCIONES.find((r) => r.key === u.rol)?.label}
              </div>
            </div>
            <button
              className={"switch" + (u.activo ? " on" : "")}
              disabled={busyId === u.id || u.id === perfil.id}
              onClick={() => cambiarEstado(u)}
              aria-label="Activar/desactivar"
            >
              <i />
            </button>
          </div>

          <div className="urol">
            {ROL_OPCIONES.map((r) => (
              <button
                key={r.key}
                className={"rchip" + (u.rol === r.key ? " on" : "")}
                disabled={busyId === u.id || u.id === perfil.id}
                onClick={() => cambiarRol(u, r.key)}
              >
                {r.label}
              </button>
            ))}
          </div>
          {!u.activo && (
            <div className="uoff">Cuenta desactivada · no puede ingresar</div>
          )}
        </div>
      ))}

      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Users size={22} />
          </div>
          {usuarios.length === 0
            ? "No hay usuarios"
            : "Ningún usuario coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

function UsuarioForm({ setDetail, notify }) {
  const [f, setF] = useState({
    nombre: "",
    email: "",
    password: "",
    rol: "operario",
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));
  const valid =
    f.nombre.trim() && f.email.includes("@") && f.password.length >= 6;

  const save = async () => {
    setBusy(true);
    setErr("");
    try {
      await crearUsuario(f);
      notify("Usuario creado");
      setDetail(null);
    } catch (e) {
      setErr(e.message || "No se pudo crear el usuario");
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      {err && (
        <div className="hint-err" style={{ marginBottom: 4 }}>
          {err}
        </div>
      )}

      <div className="field">
        <label>
          Nombre y apellido <span className="req">*</span>
        </label>
        <input
          value={f.nombre}
          onChange={(e) => set("nombre", e.target.value)}
          placeholder="Marcelo Sosa"
        />
      </div>

      <div className="field">
        <label>
          E-mail <span className="req">*</span>
        </label>
        <input
          type="email"
          autoCapitalize="none"
          value={f.email}
          onChange={(e) => set("email", e.target.value)}
          placeholder="operario@empresa.com"
        />
      </div>

      <div className="field">
        <label>
          Contraseña inicial <span className="req">*</span>
        </label>
        <input
          type="text"
          value={f.password}
          onChange={(e) => set("password", e.target.value)}
          placeholder="Mínimo 6 caracteres"
        />
        <div style={{ fontSize: 11.5, color: "var(--ink2)", marginTop: 6 }}>
          Compartila con la persona; puede cambiarla luego.
        </div>
      </div>

      <div className="field">
        <label>
          Rol <span className="req">*</span>
        </label>
        <div className="rolist">
          {ROL_OPCIONES.map((r) => (
            <button
              key={r.key}
              className={"rolopt" + (f.rol === r.key ? " on" : "")}
              onClick={() => set("rol", r.key)}
            >
              <span className="rr">{r.label}</span>
              <span className="rd">{r.desc}</span>
            </button>
          ))}
        </div>
      </div>

      <button
        className="btn btn-primary"
        style={{ marginTop: 22 }}
        disabled={!valid || busy}
        onClick={save}
      >
        <Check size={18} strokeWidth={2.5} /> Crear usuario
      </button>
    </>
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
      <div
        className="mono"
        style={{ fontWeight: 700, fontSize: 15, marginTop: 3 }}
      >
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
          <button
            key={"m" + s}
            className="cbtn l"
            onClick={() => onChange(Math.max(0, value - s))}
          >
            −{s}
          </button>
        ))}
      <input
        className="cnum"
        inputMode="numeric"
        value={value}
        onChange={(e) =>
          onChange(Number(e.target.value.replace(/\D/g, "")) || 0)
        }
        onFocus={(e) => e.target.select()}
      />
      {asc.map((s) => (
        <button
          key={"p" + s}
          className="cbtn r"
          onClick={() => onChange(value + s)}
        >
          +{s}
        </button>
      ))}
    </div>
  );
}
