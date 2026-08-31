import React, { useState, useEffect, useCallback } from "react";
import { Circle, Check } from "lucide-react";
import { supabase } from "./supabaseClient";
import {
  fetchPerfil,
  fetchArticulos,
  fetchPedidos,
  fetchTareas,
  contarTareasEnCurso,
} from "./api";
import { ROLES } from "./lib/constants";

import Shell from "./components/Shell";
import AppBar, { tabLabel, tabIcon } from "./components/AppBar";

import Login from "./pages/Login";
import Tablero from "./pages/Tablero";
import Articulos, { ArticuloDetalle, ArticuloForm } from "./pages/Articulos";
import Pedidos, { PedidoDetalle, PedidoForm } from "./pages/Pedidos";
import Tareas from "./pages/Tareas";
import Registrar from "./pages/Registrar";
import Usuarios, { UsuarioForm } from "./pages/Usuarios";
import Guia from "./pages/Guia";

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
        onGuia={() => setDetail({ type: "guia" })}
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

/* ---------- Router de pantallas ---------- */
function Screen(props) {
  const { tab, detail } = props;
  if (detail?.type === "art") return <ArticuloDetalle {...props} />;
  if (detail?.type === "artNew") return <ArticuloForm {...props} />;
  if (detail?.type === "ped") return <PedidoDetalle {...props} />;
  if (detail?.type === "pedNew") return <PedidoForm {...props} />;
  if (detail?.type === "usrNew") return <UsuarioForm {...props} />;
  if (detail?.type === "guia") return <Guia rol={props.rol} />;
  if (tab === "tablero") return <Tablero {...props} />;
  if (tab === "articulos") return <Articulos {...props} />;
  if (tab === "pedidos") return <Pedidos {...props} />;
  if (tab === "tareas") return <Tareas {...props} />;
  if (tab === "registrar") return <Registrar {...props} />;
  if (tab === "usuarios") return <Usuarios {...props} />;
  return null;
}
