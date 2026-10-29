import React, { useEffect, useState } from "react";
import {
  catalogos,
  rpc,
  solicitudes,
  gestionarSolicitud,
} from "../lib/plantaApi";
import { construirLibro } from "../lib/exportarExcel";
const inicial = () => ({
  tipo: "mantenimiento",
  destino: "",
  detalle: "",
  preventivo: false,
  asignado_id: "",
});
export default function Mantenimiento({ rol }) {
  const [rows, setRows] = useState(null),
    [historia, setHistoria] = useState([]),
    [catalogo, setCatalogo] = useState(null),
    [usuarios, setUsuarios] = useState([]),
    [form, setForm] = useState(inicial),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [estado, setEstado] = useState("pendientes"),
    [tipo, setTipo] = useState(""),
    [asignado, setAsignado] = useState(""),
    [destino, setDestino] = useState(""),
    [edicion, setEdicion] = useState({}),
    [solicitudId, setSolicitudId] = useState(() => crypto.randomUUID());
  const gestor = rol === "admin" || rol === "supervisor";
  const cargar = async () => {
    const [s, c, u, h] = await Promise.all([
      solicitudes(),
      catalogos(),
      gestor ? rpc("ejecutores_mantenimiento") : Promise.resolve([]),
      rpc("exportar_mantenimientos"),
    ]);
    setHistoria(h.filas || []);
    setRows(s);
    setCatalogo(c);
    setUsuarios(u);
  };
  useEffect(() => {
    let live = true;
    cargar().catch((e) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, []);
  const ejecutar = async (fn) => {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await fn();
      await cargar();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };
  const crear = (e) => {
    e.preventDefault();
    ejecutar(async () => {
      const [clase, id] = form.destino.split(":");
      await gestionarSolicitud("crear", solicitudId, {
        tipo: form.tipo,
        detalle: form.tipo === "molienda" ? "" : form.detalle,
        preventivo: form.tipo === "mantenimiento" && form.preventivo,
        asignado_id: form.asignado_id || null,
        maquina_id: form.tipo === "mantenimiento" && clase === "m" ? id : null,
        equipo_id: form.tipo === "mantenimiento" && clase === "e" ? id : null,
      });
      setForm(inicial());
      setSolicitudId(crypto.randomUUID());
    });
  };
  const editar = (id, k, v) =>
    setEdicion((d) => ({ ...d, [id]: { ...d[id], [k]: v } }));
  const nombre = (s) =>
    s.maquina_id
      ? catalogo?.maquinas.find((m) => m.id === s.maquina_id)?.nombre
      : s.equipo_id
        ? catalogo?.equipos.find((m) => m.id === s.equipo_id)?.nombre
        : "Molienda";
  const visibles = (rows || []).filter(
    (s) =>
      (estado === "todos" ||
        (estado === "pendientes"
          ? s.estado !== "resuelta"
          : s.estado === estado)) &&
      (!tipo || s.tipo === tipo) &&
      (!asignado || s.asignado_id === asignado) &&
      (!destino || (s.maquina_id || s.equipo_id) === destino),
  );
  const exportar = () =>
    ejecutar(async () => {
      const XLSX = await import("xlsx");
      const filas = visibles
        .map((s) => ({
          id: s.id,
          tipo: s.tipo,
          estado: s.estado,
          equipo: nombre(s) || "",
          asignado:
            usuarios.find((u) => u.id === s.asignado_id)?.nombre ||
            s.asignado_id ||
            "",
          solicitado: s.creado,
          detalle: s.detalle,
        }))
        .map((r) =>
          Object.fromEntries(Object.entries(r).map(([k, v]) => [k, String(v)])),
        );
      const columnas = Object.keys(
        filas[0] || {
          id: "",
          tipo: "",
          estado: "",
          equipo: "",
          asignado: "",
          solicitado: "",
          detalle: "",
        },
      ).map((nombre) => ({ nombre, tipo: "text" }));
      const libro = construirLibro(
        {
          tabla: "solicitudes_trabajo",
          filas,
          columnas,
          total: String(filas.length),
          exportado_en: new Date().toISOString(),
          alcance: "Listado filtrado según permisos",
        },
        XLSX,
      );
      XLSX.writeFile(libro, "solicitudes.xlsx");
    });
  return (
    <section className="gestion">
      <h2>Mantenimiento y molienda</h2>
      {error && <p role="alert">{error}</p>}
      {!rows ? (
        <button className="btn" onClick={() => ejecutar(async () => {})}>
          Reintentar carga
        </button>
      ) : (
        <>
          {gestor && (
            <details className="card">
              <summary>Solicitar tarea</summary>
              <form onSubmit={crear}>
                <fieldset disabled={busy}>
                  <label>
                    Tipo
                    <select
                      value={form.tipo}
                      onChange={(e) =>
                        setForm((f) => ({ ...f, tipo: e.target.value }))
                      }
                    >
                      <option value="mantenimiento">Mantenimiento</option>
                      <option value="molienda">Molienda</option>
                    </select>
                  </label>
                  {form.tipo === "mantenimiento" && (
                    <>
                      <label>
                        Máquina o equipo
                        <select
                          required
                          value={form.destino}
                          onChange={(e) =>
                            setForm((f) => ({ ...f, destino: e.target.value }))
                          }
                        >
                          <option value="">Seleccionar</option>
                          {["maquinas", "equipos"].flatMap((t, i) =>
                            catalogo[t]
                              .filter((m) => m.activo)
                              .map((m) => (
                                <option
                                  key={m.id}
                                  value={(i ? "e" : "m") + ":" + m.id}
                                >
                                  {i ? "Equipo" : "Máquina"} · {m.codigo} ·{" "}
                                  {m.nombre}
                                </option>
                              )),
                          )}
                        </select>
                      </label>
                      <label>
                        Detalle
                        <textarea
                          required
                          maxLength={5000}
                          value={form.detalle}
                          onChange={(e) =>
                            setForm((f) => ({ ...f, detalle: e.target.value }))
                          }
                        />
                      </label>
                      <label>
                        <input
                          type="checkbox"
                          checked={form.preventivo}
                          onChange={(e) =>
                            setForm((f) => ({
                              ...f,
                              preventivo: e.target.checked,
                            }))
                          }
                        />{" "}
                        Preventivo
                      </label>
                    </>
                  )}
                  <label>
                    Asignar a
                    <select
                      value={form.asignado_id}
                      onChange={(e) =>
                        setForm((f) => ({ ...f, asignado_id: e.target.value }))
                      }
                    >
                      <option value="">Sin asignar</option>
                      {usuarios.map((u) => (
                        <option key={u.id} value={u.id}>
                          {u.nombre}
                        </option>
                      ))}
                    </select>
                  </label>
                  <button className="btn btn-primary">Solicitar</button>
                </fieldset>
              </form>
            </details>
          )}
          <div className="card">
            <label>
              Estado
              <select
                value={estado}
                onChange={(e) => setEstado(e.target.value)}
              >
                {[
                  "pendientes",
                  "pendiente",
                  "asignada",
                  "en_curso",
                  "resuelta",
                  "todos",
                ].map((x) => (
                  <option key={x} value={x}>
                    {x.replace("_", " ")}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Tipo
              <select value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos</option>
                <option value="mantenimiento">Mantenimiento</option>
                <option value="molienda">Molienda</option>
              </select>
            </label>
            {gestor && (
              <label>
                Asignado
                <select
                  value={asignado}
                  onChange={(e) => setAsignado(e.target.value)}
                >
                  <option value="">Todos</option>
                  {usuarios.map((u) => (
                    <option key={u.id} value={u.id}>
                      {u.nombre}
                    </option>
                  ))}
                </select>
              </label>
            )}
            <label>
              Máquina/equipo
              <select
                value={destino}
                onChange={(e) => setDestino(e.target.value)}
              >
                <option value="">Todos</option>
                {[...catalogo.maquinas, ...catalogo.equipos].map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.codigo} · {m.nombre}
                  </option>
                ))}
              </select>
            </label>
            <button
              className="btn btn-ghost"
              disabled={busy}
              onClick={exportar}
            >
              Descargar reporte
            </button>
          </div>
          <p>
            {visibles.length} solicitudes ·{" "}
            {rows.filter((s) => s.estado !== "resuelta").length} pendientes
          </p>
          {visibles.map((s) => {
            const d = edicion[s.id] || {};
            return (
              <article className="card" key={s.id}>
                <h3>
                  {s.tipo === "molienda"
                    ? "Molienda"
                    : "Mantenimiento · " + nombre(s)}
                </h3>
                <p>
                  {s.estado.replace("_", " ")} ·{" "}
                  {new Date(s.creado).toLocaleString()} ·{" "}
                  {usuarios.find((u) => u.id === s.asignado_id)?.nombre ||
                    (!gestor ? "Asignada a vos" : "Sin asignar")}
                </p>
                <p>{s.detalle}</p>
                {s.estado === "resuelta" ? (
                  <p>
                    {s.resolucion} · {s.minutos} minutos
                  </p>
                ) : (
                  <fieldset disabled={busy}>
                    {gestor && (
                      <>
                        <label>
                          Asignación
                          <select
                            value={d.asignado_id || s.asignado_id || ""}
                            onChange={(e) =>
                              editar(s.id, "asignado_id", e.target.value)
                            }
                          >
                            <option value="">Seleccionar usuario</option>
                            {usuarios.map((u) => (
                              <option key={u.id} value={u.id}>
                                {u.nombre}
                              </option>
                            ))}
                          </select>
                        </label>
                        <button
                          className="btn btn-ghost"
                          disabled={!(d.asignado_id || s.asignado_id)}
                          onClick={() =>
                            ejecutar(() =>
                              gestionarSolicitud(
                                "asignar",
                                s.id,
                                { asignado_id: d.asignado_id || s.asignado_id },
                                s.revision,
                              ),
                            )
                          }
                        >
                          Asignar / reasignar
                        </button>
                      </>
                    )}
                    {s.estado === "asignada" && (
                      <button
                        className="btn btn-primary"
                        onClick={() =>
                          ejecutar(() =>
                            gestionarSolicitud("iniciar", s.id, {}, s.revision),
                          )
                        }
                      >
                        Iniciar
                      </button>
                    )}
                    {s.asignado_id && (
                      <form
                        onSubmit={(e) => {
                          e.preventDefault();
                          ejecutar(() =>
                            gestionarSolicitud(
                              "resolver",
                              s.id,
                              {
                                minutos: Number(d.minutos),
                                resolucion: d.resolucion || "",
                              },
                              s.revision,
                            ),
                          );
                        }}
                      >
                        <label>
                          Minutos de trabajo
                          <input
                            type="number"
                            required
                            min="1"
                            step="1"
                            value={d.minutos || ""}
                            onChange={(e) =>
                              editar(s.id, "minutos", e.target.value)
                            }
                          />
                        </label>
                        {s.tipo === "mantenimiento" && (
                          <label>
                            Trabajo realizado
                            <textarea
                              required
                              maxLength={5000}
                              value={d.resolucion || ""}
                              onChange={(e) =>
                                editar(s.id, "resolucion", e.target.value)
                              }
                            />
                          </label>
                        )}
                        <button className="btn btn-primary">
                          Resolver tarea
                        </button>
                      </form>
                    )}
                  </fieldset>
                )}
              </article>
            );
          })}
          <details className="card">
            <summary>Intervenciones anteriores</summary>
            <p>
              Trabajos ejecutados, incluidos los registros anteriores al
              circuito de solicitudes.
            </p>
            {historia.map((h) => (
              <div className="card" key={h.id}>
                <p>
                  {h.fecha_ejecucion} · {h.ejecutor_nombre} · {h.minutos}{" "}
                  minutos
                </p>
                <p>{h.detalle}</p>
                <small>Resuelto</small>
              </div>
            ))}
          </details>
        </>
      )}
    </section>
  );
}
