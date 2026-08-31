import React, { useState, useMemo } from "react";
import {
  Package,
  Plus,
  ChevronLeft,
  ChevronDown,
  Check,
  Settings2,
} from "lucide-react";
import { saveArticulo, setArticuloActivo } from "../api";
import { ACTS } from "../lib/constants";
import { findArt, norm } from "../lib/format";
import SearchBox from "../components/SearchBox";
import Highlight from "../components/Highlight";

export default function Articulos({ arts, setDetail }) {
  const [q, setQ] = useState("");
  const [cats, setCats] = useState([]); // categorías seleccionadas (multi)
  const [abierto, setAbierto] = useState(false);

  const categorias = useMemo(
    () => [...new Set(arts.map((a) => a.categoria).filter(Boolean))].sort(),
    [arts],
  );

  const toggleCat = (c) =>
    setCats((s) => (s.includes(c) ? s.filter((x) => x !== c) : [...s, c]));

  const lista = useMemo(() => {
    const nq = norm(q.trim());
    return arts.filter((a) => {
      if (cats.length && !cats.includes(a.categoria)) return false;
      if (!nq) return true;
      return (
        norm(a.codigo).includes(nq) ||
        norm(a.nombre).includes(nq) ||
        norm(a.molde).includes(nq) ||
        norm(a.maquina).includes(nq) ||
        norm(a.material).includes(nq) ||
        norm(a.categoria).includes(nq)
      );
    });
  }, [arts, q, cats]);

  const etiqueta =
    cats.length === 0
      ? "Todas las categorías"
      : cats.length === 1
        ? cats[0]
        : `${cats.length} categorías`;

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
        placeholder="Buscar por código, nombre, categoría…"
      />

      {categorias.length > 0 && (
        <div className="dropdown">
          <button
            className={"ddbtn" + (cats.length ? " act" : "")}
            onClick={() => setAbierto((v) => !v)}
          >
            <span>{etiqueta}</span>
            <ChevronDown
              size={17}
              className={"ddchev" + (abierto ? " op" : "")}
            />
          </button>
          {abierto && (
            <div className="ddmenu">
              {categorias.map((c) => {
                const on = cats.includes(c);
                return (
                  <button
                    key={c}
                    className="ddopt"
                    onClick={() => toggleCat(c)}
                  >
                    <span className={"ddcheck" + (on ? " on" : "")}>
                      {on && <Check size={13} strokeWidth={3} color="#fff" />}
                    </span>
                    <span className="ddtxt">{c}</span>
                    <span className="ddcount">
                      {arts.filter((a) => a.categoria === c).length}
                    </span>
                  </button>
                );
              })}
              {cats.length > 0 && (
                <button
                  className="ddclear"
                  onClick={() => {
                    setCats([]);
                  }}
                >
                  Limpiar selección
                </button>
              )}
            </div>
          )}
        </div>
      )}

      {q || cats.length ? (
        <div className="search-count">
          {lista.length} de {arts.length} artículos
        </div>
      ) : null}

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
              {a.categoria ? ` · ${a.categoria}` : ""}
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

export function ArticuloDetalle({ arts, detail, setDetail, notify, reloadArts }) {
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
        {a.categoria && (
          <div style={{ marginTop: 10 }}>
            <span className="catpill">{a.categoria}</span>
          </div>
        )}
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

export function ArticuloForm({ arts, detail, setDetail, notify, reloadArts }) {
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
          categoria: "",
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
      <div className="field">
        <label>Categoría</label>
        <input
          value={f.categoria || ""}
          onChange={(e) => set("categoria", e.target.value)}
          placeholder="Ej: PRODUCTOS EMBOLSADOS"
          list="lista-categorias"
        />
        <datalist id="lista-categorias">
          {[...new Set(arts.map((x) => x.categoria).filter(Boolean))].map(
            (c) => (
              <option key={c} value={c} />
            ),
          )}
        </datalist>
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
