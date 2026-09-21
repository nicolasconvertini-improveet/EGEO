import React, { useState, useEffect, useCallback, useMemo } from "react";
import { Check, Users, UserPlus } from "lucide-react";
import { fetchUsuarios, updateUsuario, crearUsuario } from "../api";
import { norm } from "../lib/format";
import SearchBox from "../components/SearchBox";
import Highlight from "../components/Highlight";

const ROL_OPCIONES = [
  { key: "operario", label: "Operario", desc: "Registra tareas" },
  { key: "supervisor", label: "Supervisor", desc: "Además crea órdenes" },
  { key: "admin", label: "Administrador", desc: "Acceso total" },
];

export default function Usuarios({ perfil, notify, setDetail }) {
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
    return usuarios.filter((u) => norm(u.nombre).includes(nq) || norm(u.rol).includes(nq));
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
      <button className="btn btn-dark" style={{ marginBottom: 12 }} onClick={() => setDetail({ type: "usrNew" })}>
        <UserPlus size={18} strokeWidth={2.4} /> Nuevo usuario
      </button>

      <SearchBox value={q} onChange={setQ} placeholder="Buscar por nombre o rol…" />
      {q && (
        <div className="search-count">
          {lista.length} de {usuarios.length} usuarios
        </div>
      )}

      {lista.map((u) => (
        <div className="card usercard" key={u.id} style={{ opacity: u.activo ? 1 : 0.62 }}>
          <div className="uhead">
            <div className="uav">{(u.nombre || "?").slice(0, 2).toUpperCase()}</div>
            <div className="umid">
              <div className="un">
                <Highlight text={u.nombre || "(sin nombre)"} query={q} />
                {u.id === perfil.id && <span className="uyou">vos</span>}
              </div>
              <div className="us">{ROL_OPCIONES.find((r) => r.key === u.rol)?.label}</div>
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
          {!u.activo && <div className="uoff">Cuenta desactivada · no puede ingresar</div>}
        </div>
      ))}

      {lista.length === 0 && (
        <div className="empty">
          <div className="ic">
            <Users size={22} />
          </div>
          {usuarios.length === 0 ? "No hay usuarios" : "Ningún usuario coincide con la búsqueda"}
        </div>
      )}
    </>
  );
}

export function UsuarioForm({ setDetail, notify }) {
  const [f, setF] = useState({
    nombre: "",
    email: "",
    password: "",
    rol: "operario",
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const set = (k, v) => setF((s) => ({ ...s, [k]: v }));
  const valid = f.nombre.trim() && f.email.includes("@") && f.password.length >= 6;

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
        <input value={f.nombre} onChange={(e) => set("nombre", e.target.value)} placeholder="Marcelo Sosa" />
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
        <input type="text" value={f.password} onChange={(e) => set("password", e.target.value)} placeholder="Mínimo 6 caracteres" />
        <div style={{ fontSize: 11.5, color: "var(--ink2)", marginTop: 6 }}>Compartila con la persona; puede cambiarla luego.</div>
      </div>

      <div className="field">
        <label>
          Rol <span className="req">*</span>
        </label>
        <div className="rolist">
          {ROL_OPCIONES.map((r) => (
            <button key={r.key} className={"rolopt" + (f.rol === r.key ? " on" : "")} onClick={() => set("rol", r.key)}>
              <span className="rr">{r.label}</span>
              <span className="rd">{r.desc}</span>
            </button>
          ))}
        </div>
      </div>

      <button className="btn btn-primary" style={{ marginTop: 22 }} disabled={!valid || busy} onClick={save}>
        <Check size={18} strokeWidth={2.5} /> Crear usuario
      </button>
    </>
  );
}
