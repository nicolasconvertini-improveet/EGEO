import React, { useEffect, useState } from "react";
import { catalogos, guardarActivo, rpc } from "../lib/plantaApi";
const nuevoMolde = () => ({
  codigo: "",
  maquina_id: "",
  material: "",
  material_ciclo: 1,
  unidad_material: "g",
  segundos_ciclo: 1,
  activo: true,
  articulos: [],
});
export default function Planta({ arts, rol }) {
  const [tipo, setTipo] = useState("moldes"),
    [datos, setDatos] = useState(null),
    [form, setForm] = useState(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  const cargar = () =>
    catalogos()
      .then(setDatos)
      .catch((e) => setError(e.message));
  useEffect(() => {
    cargar();
  }, []);
  const cambiar = (k, v) => setForm((f) => ({ ...f, [k]: v }));
  const guardar = async (e) => {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      if (tipo === "moldes") {
        const { id, articulos, ...d } = form;
        await rpc("guardar_molde", {
          p_id: id || null,
          p_datos: d,
          p_articulos: articulos,
        });
      } else await guardarActivo(tipo, form);
      await cargar();
      setForm(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };
  if (rol !== "admin")
    return <p role="alert">Acceso exclusivo para administradores.</p>;
  return (
    <section className="gestion">
      <h2>Máquinas, equipos y moldes</h2>
      <div className="planta-toolbar" aria-label="Gestión de planta">
        {["moldes", "maquinas", "equipos"].map((t) => (
          <button
            className={"chip" + (tipo === t ? " on" : "")}
            key={t}
            onClick={() => {
              setTipo(t);
              setForm(null);
              setError("");
            }}
          >
            {t === "maquinas"
              ? "Máquinas"
              : t === "equipos"
                ? "Equipos"
                : "Moldes"}
          </button>
        ))}
        {!form && (
          <button
            className="btn btn-primary"
            onClick={() =>
              setForm(
                tipo === "moldes"
                  ? nuevoMolde()
                  : { codigo: "", nombre: "", activo: true },
              )
            }
          >
            Nuevo registro
          </button>
        )}
      </div>
      {error && <p role="alert">{error}</p>}
      {!datos ? (
        <button onClick={cargar}>Reintentar carga</button>
      ) : (
        <>
          {form && (
            <form className="card gestion-form" onSubmit={guardar}>
              <button
                type="button"
                className="btn btn-ghost"
                disabled={busy}
                onClick={() => setForm(null)}
              >
                Volver al listado
              </button>
              <fieldset disabled={busy}>
                <legend>{form.id ? "Editar" : "Nuevo"}</legend>
                <label>
                  Código
                  <input
                    required
                    value={form.codigo}
                    onChange={(e) => cambiar("codigo", e.target.value)}
                  />
                </label>
                {tipo !== "moldes" ? (
                  <label>
                    Descripción
                    <input
                      required
                      value={form.nombre}
                      onChange={(e) => cambiar("nombre", e.target.value)}
                    />
                  </label>
                ) : (
                  <>
                    <label>
                      Máquina
                      <select
                        required
                        value={form.maquina_id}
                        onChange={(e) => cambiar("maquina_id", e.target.value)}
                      >
                        <option value="">Seleccionar</option>
                        {datos.maquinas
                          .filter((m) => m.activo || m.id === form.maquina_id)
                          .map((m) => (
                            <option key={m.id} value={m.id}>
                              {m.codigo} · {m.nombre}
                              {!m.activo ? " (inactiva)" : ""}
                            </option>
                          ))}
                      </select>
                    </label>
                    <label>
                      Material
                      <input
                        required
                        value={form.material}
                        onChange={(e) => cambiar("material", e.target.value)}
                      />
                    </label>
                    <label>
                      Material por ciclo
                      <input
                        type="number"
                        min="0.000001"
                        step="any"
                        required
                        value={form.material_ciclo}
                        onChange={(e) =>
                          cambiar("material_ciclo", e.target.value)
                        }
                      />
                    </label>
                    <label>
                      Unidad de material
                      <input
                        required
                        value={form.unidad_material}
                        onChange={(e) =>
                          cambiar("unidad_material", e.target.value)
                        }
                      />
                    </label>
                    <label>
                      Segundos por ciclo
                      <input
                        type="number"
                        min="0.000001"
                        step="any"
                        required
                        value={form.segundos_ciclo}
                        onChange={(e) =>
                          cambiar("segundos_ciclo", e.target.value)
                        }
                      />
                    </label>
                    <h3>Artículos por ciclo</h3>
                    {form.articulos.map((r, i) => (
                      <div className="card" key={i}>
                        <label>
                          Artículo
                          <select
                            required
                            value={r.articulo_id}
                            onChange={(e) =>
                              cambiar(
                                "articulos",
                                form.articulos.map((x, j) =>
                                  j === i
                                    ? { ...x, articulo_id: e.target.value }
                                    : x,
                                ),
                              )
                            }
                          >
                            <option value="">Seleccionar</option>
                            {arts
                              .filter((a) => a.activo || a.id === r.articulo_id)
                              .map((a) => (
                                <option key={a.id} value={a.id}>
                                  {a.codigo} · {a.nombre}
                                </option>
                              ))}
                          </select>
                        </label>
                        <label>
                          Unidades por ciclo
                          <input
                            required
                            type="number"
                            min="1"
                            step="1"
                            value={r.unidades_ciclo}
                            onChange={(e) =>
                              cambiar(
                                "articulos",
                                form.articulos.map((x, j) =>
                                  j === i
                                    ? {
                                        ...x,
                                        unidades_ciclo: Number(e.target.value),
                                      }
                                    : x,
                                ),
                              )
                            }
                          />
                        </label>
                        <button
                          type="button"
                          className="btn btn-ghost"
                          onClick={() =>
                            cambiar(
                              "articulos",
                              form.articulos.filter((_, j) => j !== i),
                            )
                          }
                        >
                          Quitar artículo
                        </button>
                      </div>
                    ))}
                    <button
                      type="button"
                      className="btn btn-ghost"
                      onClick={() =>
                        cambiar("articulos", [
                          ...form.articulos,
                          { articulo_id: "", unidades_ciclo: 1 },
                        ])
                      }
                    >
                      Agregar artículo
                    </button>
                  </>
                )}
                <label>
                  <input
                    type="checkbox"
                    checked={form.activo}
                    onChange={(e) => cambiar("activo", e.target.checked)}
                  />{" "}
                  Activo
                </label>
                <button
                  className="btn btn-primary"
                  disabled={tipo === "moldes" && !form.articulos.length}
                >
                  Guardar
                </button>
                <button
                  type="button"
                  className="btn btn-ghost"
                  onClick={() => setForm(null)}
                >
                  Cancelar
                </button>
              </fieldset>
            </form>
          )}
          {!form && (
            <div className="gestion-lista">
              {datos[tipo].map((row) => (
                <button
                  className="rowitem"
                  key={row.id}
                  onClick={() => setForm({ ...row })}
                >
                  <span>
                    {row.codigo} · {row.nombre || row.material} ·{" "}
                    {row.activo ? "Activo" : "Inactivo"}
                    {row.articulos
                      ? ` · ${row.articulos.length} artículos`
                      : ""}
                  </span>
                </button>
              ))}
            </div>
          )}
        </>
      )}
    </section>
  );
}
