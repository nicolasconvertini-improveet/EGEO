import React, { useEffect, useState } from "react";
import ConfirmDialog from "./ConfirmDialog";
import { cerrarMolde } from "../api";
import { minutosValidos, pendienteCierreMolde } from "../lib/montaje";
import { fmtDT } from "../lib/format";

function Tiempo({ label, value, onChange, disabled = false }) {
  return (
    <label className="molde-tiempo">
      {label} (minutos)
      <input
        type="number"
        required
        disabled={disabled}
        min="0"
        step="any"
        value={value}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  );
}
export function InicioInyectado({ pedido, busy, onIniciar }) {
  const [abierto, setAbierto] = useState(false),
    [confirmado, setConfirmado] = useState(false),
    [subida, setSubida] = useState(""),
    [calentamiento, setCalentamiento] = useState("");
  const falta = pedido.requiereCierreMolde && !pedido.controlMolde;
  useEffect(() => {
    if (pedido.controlMolde) setAbierto(false);
  }, [pedido.controlMolde?.pedido_id]);
  return (
    <>
      <button
        type="button"
        className="btn btn-dark"
        disabled={busy}
        onClick={() => {
          if (!falta) return onIniciar(null);
          setConfirmado(false);
          setSubida("");
          setCalentamiento("");
          setAbierto(true);
        }}
      >
        {!pedido.requiereCierreMolde
          ? "Iniciar tarea"
          : falta
            ? "Tomar orden y subir molde"
            : "Retomar inyectado"}
      </button>
      <ConfirmDialog
        className="modal-molde"
        abierto={abierto}
        titulo="Tomar orden y subir molde"
        textoConfirmar="Registrar tiempos e iniciar producción"
        busy={busy}
        deshabilitado={
          !confirmado ||
          !minutosValidos(subida) ||
          !minutosValidos(calentamiento)
        }
        onCancelar={() => setAbierto(false)}
        onConfirmar={async () => {
          const iniciada = await onIniciar({
            confirmado,
            subida_minutos: Number(subida),
            calentamiento_minutos: Number(calentamiento),
          });
          if (iniciada) setAbierto(false);
        }}
      >
        <p>
          ¿Confirmás que vas a tomar la orden {pedido.codigo} y subir el molde?
          Completá la subida y el calentamiento antes de iniciar producción.
          Estos tiempos se registran una sola vez por orden.
        </p>
        <label className="molde-confirmacion">
          <input
            type="checkbox"
            disabled={busy}
            checked={confirmado}
            onChange={(e) => setConfirmado(e.target.checked)}
          />
          Confirmo que tomo esta orden y realizo la subida del molde.
        </label>
        {confirmado && (
          <>
            <Tiempo
              label="Subida del molde"
              value={subida}
              onChange={setSubida}
              disabled={busy}
            />
            <Tiempo
              label="Calentamiento del molde"
              value={calentamiento}
              onChange={setCalentamiento}
              disabled={busy}
            />
            <small>
              Si un tiempo no aplica, ingresá 0 explícitamente. No lo registres
              además como pausa de la tarea.
            </small>
          </>
        )}
      </ConfirmDialog>
    </>
  );
}
export function TiemposMolde({ pedido }) {
  const m = pedido.controlMolde;
  if (!pedido.requiereCierreMolde) return null;
  return (
    <section className="card">
      <h3>Control de molde</h3>
      {!m ? (
        <p>Montaje pendiente de registrar.</p>
      ) : (
        <>
          <p>
            Subida: {m.subida_minutos} min · Calentamiento:{" "}
            {m.calentamiento_minutos} min
          </p>
          <p>Registro de montaje: {fmtDT(m.montado_en)}</p>
          {m.bajado_en ? (
            <p>
              Bajada: {m.bajada_minutos} min · Limpieza confirmada ·{" "}
              {fmtDT(m.bajado_en)}
            </p>
          ) : (
            <p>
              {pendienteCierreMolde(pedido)
                ? "Producción completa. Pendiente de bajada y limpieza."
                : "El molde permanece montado entre tareas."}
            </p>
          )}
        </>
      )}
    </section>
  );
}
export function CierreMolde({ pedido, reloadPeds, notify }) {
  const [abierto, setAbierto] = useState(false),
    [bajada, setBajada] = useState(""),
    [limpieza, setLimpieza] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  if (!pendienteCierreMolde(pedido)) return null;
  return (
    <section className="card cierre-molde">
      <h3>Orden {pedido.codigo}: producción completa</h3>
      <p>
        Falta registrar la bajada y confirmar la limpieza para cerrar la orden.
        No inicies otra tarea en esta orden.
      </p>
      <button
        className="btn btn-primary"
        type="button"
        disabled={
          busy ||
          !pedido.controlMolde.puede_cerrar ||
          pedido.controlMolde.tareas_pendientes
        }
        onClick={() => {
          setError("");
          setAbierto(true);
        }}
      >
        Registrar bajada y cerrar orden
      </button>
      {pedido.controlMolde.tareas_pendientes && (
        <p>
          Primero finalizá y registrá todas las tareas abiertas de esta orden.
        </p>
      )}
      <ConfirmDialog
        className="modal-molde"
        abierto={abierto}
        titulo="Recordá limpiar el molde"
        textoConfirmar="Confirmar limpieza y cerrar orden"
        busy={busy}
        deshabilitado={!minutosValidos(bajada) || !limpieza}
        onCancelar={() => setAbierto(false)}
        onConfirmar={async () => {
          if (busy) return;
          setBusy(true);
          setError("");
          try {
            await cerrarMolde(pedido, bajada, limpieza);
            await reloadPeds();
            setAbierto(false);
            notify("Orden cerrada: bajada y limpieza registradas");
          } catch (e) {
            setError(e.message || "No se pudo cerrar la orden");
            await reloadPeds();
          } finally {
            setBusy(false);
          }
        }}
      >
        <Tiempo
          label="Bajada del molde"
          value={bajada}
          onChange={setBajada}
          disabled={busy}
        />
        <label className="molde-confirmacion">
          <input
            type="checkbox"
            disabled={busy}
            checked={limpieza}
            onChange={(e) => setLimpieza(e.target.checked)}
          />
          Confirmo que limpié el molde.
        </label>
        {error && <p role="alert">{error}</p>}
      </ConfirmDialog>
    </section>
  );
}
