import React, { useEffect, useState } from "react";
import { createPedido } from "../api";
import { catalogos } from "../lib/plantaApi";
import SelectorArticuloPedido from "../components/SelectorArticuloPedido";
import { norm } from "../lib/format";
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
    <form className="nueva-orden" onSubmit={guardar}>
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
        {inyectado ? (
          <>
            <label>
              Buscar molde por código, máquina o artículo
              <input
                type="search"
                value={busqueda}
                onChange={(e) => setBusqueda(e.target.value)}
              />
            </label>
            <label>
              Molde
              <select
                required
                value={form.moldeId}
                onChange={(e) => set("moldeId", e.target.value)}
              >
                <option value="">Seleccionar molde</option>
                {datos?.moldes
                  .filter((m) => {
                    const maquina = datos.maquinas.find(
                      (x) => x.id === m.maquina_id,
                    );
                    const piezas = m.articulos
                      .map((r) => arts.find((a) => a.id === r.articulo_id))
                      .filter(Boolean);
                    const texto = norm(
                      [
                        m.codigo,
                        maquina?.codigo,
                        maquina?.nombre,
                        ...piezas.flatMap((a) => [a.codigo, a.nombre]),
                      ].join(" "),
                    );
                    return (
                      m.activo &&
                      (m.id === form.moldeId ||
                        norm(busqueda)
                          .split(/\s+/)
                          .filter(Boolean)
                          .every((p) => texto.includes(p)))
                    );
                  })
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
          <SelectorArticuloPedido
            arts={arts.filter((a) => a.std[form.proceso] > 0)}
            artId={form.articuloId}
            onChange={(id) => set("articuloId", id)}
            busy={busy}
          />
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
