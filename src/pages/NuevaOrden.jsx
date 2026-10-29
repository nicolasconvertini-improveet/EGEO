import React, { useEffect, useState } from "react";
import { createPedido } from "../api";
import { catalogos } from "../lib/plantaApi";
import { ACTS } from "../lib/constants";
export default function NuevaOrden({ arts, notify, reloadPeds, setDetail }) {
  const [form, setForm] = useState({
      codigo: "",
      proceso: "inyectado",
      moldeId: "",
      articuloId: "",
      cantidad: "",
    }),
    [datos, setDatos] = useState(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [busqueda, setBusqueda] = useState("");
  useEffect(() => {
    catalogos()
      .then(setDatos)
      .catch((e) => setError(e.message));
  }, []);
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  const molde = datos?.moldes.find((m) => m.id === form.moldeId);
  const guardar = async (e) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await createPedido(form);
      await reloadPeds();
      notify("Orden creada");
      setDetail(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };
  const inyectado = form.proceso === "inyectado";
  return (
    <form className="gestion" onSubmit={guardar}>
      {error && <p role="alert">{error}</p>}
      <fieldset disabled={busy || !datos}>
        <label>
          Código de orden
          <input
            required
            value={form.codigo}
            onChange={(e) => set("codigo", e.target.value)}
          />
        </label>
        <label>
          Proceso
          <select
            value={form.proceso}
            onChange={(e) =>
              setForm((f) => ({
                ...f,
                proceso: e.target.value,
                articuloId: "",
                moldeId: "",
              }))
            }
          >
            {ACTS.map((a) => (
              <option key={a.key} value={a.key}>
                {a.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Buscar {inyectado ? "molde" : "artículo"}
          <input
            type="search"
            value={busqueda}
            onChange={(e) => setBusqueda(e.target.value)}
          />
        </label>
        {inyectado ? (
          <>
            <label>
              Molde
              <select
                required
                value={form.moldeId}
                onChange={(e) => set("moldeId", e.target.value)}
              >
                <option value="">Seleccionar molde</option>
                {datos?.moldes
                  .filter(
                    (m) =>
                      m.activo &&
                      (m.id === form.moldeId ||
                        m.codigo
                          .toLowerCase()
                          .includes(busqueda.toLowerCase())),
                  )
                  .map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.codigo} ·{" "}
                      {
                        datos.maquinas.find((x) => x.id === m.maquina_id)
                          ?.nombre
                      }
                    </option>
                  ))}
              </select>
            </label>
            {molde && (
              <div className="card">
                <p>
                  Todos los artículos del molde · {molde.segundos_ciclo} s/ciclo
                  · {molde.material_ciclo} {molde.unidad_material}/ciclo
                </p>
                {molde.articulos.map((r) => {
                  const a = arts.find((a) => a.id === r.articulo_id);
                  return (
                    <p key={r.articulo_id}>
                      {a?.codigo} · {a?.nombre} · {r.unidades_ciclo} u/ciclo ·
                      Objetivo: {Number(form.cantidad || 0) * r.unidades_ciclo}{" "}
                      u.
                    </p>
                  );
                })}
              </div>
            )}
          </>
        ) : (
          <label>
            Artículo
            <select
              required
              value={form.articuloId}
              onChange={(e) => set("articuloId", e.target.value)}
            >
              <option value="">Seleccionar artículo</option>
              {arts
                .filter(
                  (a) =>
                    a.activo &&
                    a.std[form.proceso] > 0 &&
                    (a.id === form.articuloId ||
                      `${a.codigo} ${a.nombre}`
                        .toLowerCase()
                        .includes(busqueda.toLowerCase())),
                )
                .map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.codigo} · {a.nombre}
                  </option>
                ))}
            </select>
          </label>
        )}
        <label>
          {inyectado ? "Ciclos previstos" : "Cantidad de piezas a fabricar"}
          <input
            required
            type="number"
            min="1"
            step="1"
            value={form.cantidad}
            onChange={(e) => set("cantidad", e.target.value)}
          />
        </label>
        {inyectado && (
          <p>
            La orden se completa cuando todos los artículos alcanzan su objetivo
            de piezas OK.
          </p>
        )}
        <button className="btn btn-primary">
          {busy ? "Guardando…" : "Crear orden"}
        </button>
      </fieldset>
    </form>
  );
}
