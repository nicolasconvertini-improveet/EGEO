import React, { useState, useEffect, useCallback } from "react";
import { Circle, Check } from "lucide-react";
import { supabase } from "./supabaseClient";
import { fetchPerfil, fetchArticulos, fetchPedidos, fetchTareas, contarTareasEnCurso } from "./api";
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
import Exportar from "./pages/Exportar";

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
  const [datosCargados, setDatosCargados] = useState(null);
  const [errorDatos, setErrorDatos] = useState(null);
  const [reintento, setReintento] = useState(0);
  const usuarioId = session?.user?.id;
  const clavePantalla = JSON.stringify([usuarioId, tab, detail?.type, detail?.id, detail?.edit]);

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
        setEnCurso(0);
        setDatosCargados(null);
        setErrorDatos(null);
        setDetail(null);
      }
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!usuarioId) return;
    let vigente = true;
    fetchPerfil(usuarioId)
      .then((p) => {
        if (!vigente) return;
        setPerfil(p);
        setTab(ROLES[p.rol]?.tabs[0] || "registrar");
        setDetail(null);
      })
      .catch(() => vigente && notify("No se pudo cargar el perfil", true));
    return () => {
      vigente = false;
    };
  }, [usuarioId, notify]);

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
        .catch(() => notify("Error al cargar órdenes", true)),
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

  // Leer datos compartidos sólo al entrar a una pantalla o detalle.
  // No depender del objeto session: renovar el token no debe recargar la vista.
  useEffect(() => {
    if (!usuarioId || perfil?.id !== usuarioId || !perfil?.activo) return;
    let vigente = true;
    setLoadingData(true);
    setErrorDatos(null);
    Promise.all([fetchArticulos(), fetchPedidos(), fetchTareas({ desdeDias: 60, limit: 500 }), contarTareasEnCurso()])
      .then(([nuevosArts, nuevosPeds, nuevasTars, nuevoEnCurso]) => {
        if (!vigente) return;
        setArts(nuevosArts);
        setPeds(nuevosPeds);
        setTars(nuevasTars);
        setEnCurso(nuevoEnCurso);
        setDatosCargados(clavePantalla);
      })
      .catch(() => {
        if (vigente) setErrorDatos({ clave: clavePantalla, mensaje: "No se pudieron cargar los datos de la pantalla." });
      })
      .finally(() => {
        if (vigente) setLoadingData(false);
      });
    // Ignorar respuestas de una pantalla que ya se abandonó.
    return () => {
      vigente = false;
    };
  }, [usuarioId, perfil?.id, perfil?.activo, clavePantalla, reintento]);

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
          <button className="btn btn-ghost" style={{ maxWidth: 200 }} onClick={() => supabase.auth.signOut()}>
            Salir
          </button>
        </div>
      </Shell>
    );
  if (!perfil || perfil.id !== usuarioId)
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
        onExportar={() => setDetail({ type: "exportar" })}
      />
      <div className={"body" + (tabs.length === 1 ? " nonav" : "")}>
        {errorDatos?.clave === clavePantalla ? (
          <div className="card" role="alert">
            <p>{errorDatos.mensaje}</p>
            <button className="btn btn-primary" onClick={() => setReintento((n) => n + 1)}>
              Reintentar
            </button>
          </div>
        ) : loadingData || datosCargados !== clavePantalla ? (
          <div className="center" style={{ minHeight: 260 }}>
            <div className="spinner" />
          </div>
        ) : (
          <Screen key={clavePantalla} {...shared} tab={tab} detail={detail} />
        )}
      </div>

      {toast && (
        <div className={"toast" + (toast.err ? " err" : "")}>
          <span className="tk">{toast.err ? <Circle size={13} color="#fff" /> : <Check size={13} color="#fff" strokeWidth={3} />}</span>
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
  if (detail?.type === "exportar") return <Exportar rol={props.rol} />;
  if (tab === "tablero") return <Tablero {...props} />;
  if (tab === "articulos") return <Articulos {...props} />;
  if (tab === "pedidos") return <Pedidos {...props} />;
  if (tab === "tareas") return <Tareas {...props} />;
  if (tab === "registrar") return <Registrar {...props} />;
  if (tab === "usuarios") return <Usuarios {...props} />;
  return null;
}
