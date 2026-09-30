import React, { useEffect, useRef, useState } from "react";
import { consultarEstadoPedido, cambiarEstadoPedido, fetchHistorialEstado } from "../api";
import { estadoLabel, fmtDT } from "../lib/format";

const OPCIONES = {
  pendiente: [
    ["en_curso", "Pasar a En curso"],
    ["cancelado", "Cancelar orden"],
  ],
  en_curso: [["finalizado", "Finalizar orden"]],
  cancelado: [["reabrir", "Reabrir automáticamente"]],
  finalizado: [],
};

export default function EstadoPedido({ pedidoId, notify, reloadPeds }) {
  const [actual, setActual] = useState(null);
  const [historial, setHistorial] = useState([]);
  const [total, setTotal] = useState(0);
  const [accion, setAccion] = useState("");
  const [motivo, setMotivo] = useState("");
  const [busy, setBusy] = useState(false);
  const [cargando, setCargando] = useState(false);
  const [error, setError] = useState("");
  const [recarga, setRecarga] = useState(0);
  const [limite, setLimite] = useState(20);
  const [pendiente, setPendiente] = useState(null);
  const enviando = useRef(false);

  useEffect(() => {
    let vigente = true;
    setCargando(true);
    Promise.all([consultarEstadoPedido(pedidoId), fetchHistorialEstado(pedidoId, limite)])
      .then(([orden, eventos]) => {
        if (!vigente) return;
        setActual(orden);
        setHistorial(eventos.data);
        setTotal(eventos.count);
        setError("");
      })
      .catch(() => vigente && setError("No se pudo actualizar el estado y su historial. Reintentá la consulta."))
      .finally(() => vigente && setCargando(false));
    return () => {
      vigente = false;
    };
  }, [pedidoId, recarga, limite]);

  const guardar = async (event) => {
    event.preventDefault();
    if (enviando.current || !actual || cargando || (!pendiente && (!accion || !motivo.trim()))) return;
    const solicitud = pendiente || {
      id: crypto.randomUUID(),
      pedidoId,
      revision: actual.estado_revision,
      accion,
      motivo: motivo.trim(),
    };
    enviando.current = true;
    setBusy(true);
    setPendiente(solicitud);
    setError("");
    try {
      const resultado = await cambiarEstadoPedido(solicitud);
      setPendiente(null);
      setAccion("");
      setMotivo("");
      setActual(null);
      setRecarga((n) => n + 1);
      notify(`Orden: ${estadoLabel(resultado.estado_nuevo)}`);
      await reloadPeds();
    } catch (e) {
      // Los errores de negocio confirman que no se guardó; una falla de red
      // conserva la solicitud para reintentar sin duplicar el movimiento.
      if (["22023", "40001", "42501"].includes(e?.code)) {
        notify(e.message || "No se pudo guardar el cambio", true);
        setPendiente(null);
        setActual(null);
        setAccion("");
        setRecarga((n) => n + 1);
      }
      setError(e?.message || "No se pudo confirmar el cambio. Reintentá la misma solicitud.");
    } finally {
      enviando.current = false;
      setBusy(false);
    }
  };
  return (
    <section className="card" style={{ marginTop: 18 }} aria-label="Estado e historial de la orden">
      <h3 style={{ marginTop: 0 }}>Cambiar estado</h3>
      {actual && (
        <p>
          Estado actual: <strong>{estadoLabel(actual.estado)}</strong>
        </p>
      )}
      {cargando && <p role="status">Actualizando…</p>}
      {error && (
        <p className="hint-err" role="alert">
          {error}
        </p>
      )}
      <button
        type="button"
        className="btn btn-ghost"
        disabled={busy || cargando}
        onClick={() => {
          setRecarga((n) => n + 1);
          reloadPeds();
        }}
      >
        Actualizar estado e historial
      </button>
      {actual && (OPCIONES[actual.estado]?.length > 0 || pendiente) && (
        <form onSubmit={guardar}>
          <div className="field">
            <label htmlFor="estado-accion">Acción</label>
            <select
              id="estado-accion"
              value={accion}
              required
              disabled={busy || cargando || Boolean(pendiente)}
              onChange={(e) => setAccion(e.target.value)}
            >
              <option value="">Elegí una acción</option>
              {(pendiente ? [[pendiente.accion, "Cambio pendiente de confirmación"]] : OPCIONES[actual.estado] || []).map(
                ([valor, texto]) => (
                  <option key={valor} value={valor}>
                    {texto}
                  </option>
                ),
              )}
            </select>
          </div>
          {accion === "reabrir" && <p>Quedará Pendiente si nunca tuvo tareas o En curso si tuvo actividad, incluso con cero piezas.</p>}
          {accion === "finalizado" && <p>Este cierre es manual: no modifica las piezas ni completa las etapas faltantes.</p>}
          {["cancelado", "finalizado"].includes(accion) && <p>Primero deben confirmarse todas las tareas de la orden.</p>}
          <div className="field">
            <label htmlFor="estado-motivo">Motivo obligatorio</label>
            <textarea
              id="estado-motivo"
              rows={3}
              maxLength={1000}
              required
              value={motivo}
              disabled={busy || cargando || Boolean(pendiente)}
              onChange={(e) => setMotivo(e.target.value)}
            />
          </div>
          {pendiente && !busy && <p>La respuesta no pudo confirmarse. Reintentá la misma solicitud para evitar duplicados.</p>}
          <button
            type="submit"
            className="btn btn-primary"
            style={{ marginTop: 12 }}
            disabled={busy || cargando || (!pendiente && (!accion || !motivo.trim()))}
          >
            {busy ? "Guardando…" : pendiente ? "Reintentar el mismo cambio" : "Confirmar cambio de estado"}
          </button>
        </form>
      )}
      {actual?.estado === "finalizado" && !pendiente && <p>La orden finalizada no admite cambios manuales.</p>}
      <h3>Historial de cambios manuales</h3>
      {!cargando && !historial.length && !error && <p>Sin cambios manuales registrados.</p>}
      {historial.map((h) => (
        <div key={h.id} style={{ borderTop: "1px solid var(--line)", padding: "12px 0" }}>
          <strong>
            {estadoLabel(h.estado_anterior)} → {estadoLabel(h.estado_nuevo)}
          </strong>
          <div>
            {fmtDT(h.creado)} · {h.usuario_nombre} · {h.usuario_rol === "admin" ? "Administrador" : "Supervisor"}
          </div>
          <p style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{h.motivo}</p>
        </div>
      ))}
      {total > historial.length && (
        <button type="button" className="btn btn-ghost" disabled={busy || cargando} onClick={() => setLimite((n) => n + 20)}>
          Ver más cambios ({historial.length} de {total})
        </button>
      )}
    </section>
  );
}
