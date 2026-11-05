import React, { useEffect, useRef, useId } from "react";

/* Modal de confirmación reutilizable.
   abierto: boolean · titulo, children: contenido · onConfirmar / onCancelar
   peligro: pinta el botón de confirmar en rojo (para eliminar). */
export default function ConfirmDialog({
  abierto,
  titulo,
  children,
  textoConfirmar = "Confirmar",
  textoCancelar = "Cancelar",
  peligro = false,
  busy = false,
  deshabilitado = false,
  className = "",
  onConfirmar,
  onCancelar,
}) {
  const ref = useRef(null);
  const tituloId = useId();

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (abierto && !d.open) d.showModal();
    if (!abierto && d.open) d.close();
  }, [abierto]);

  return (
    <dialog
      ref={ref}
      className={"confirm-modal" + (className ? " " + className : "")}
      aria-labelledby={tituloId}
      onCancel={(e) => {
        e.preventDefault(); // Esc = cancelar, controlado por React
        if (!busy) onCancelar();
      }}
    >
      <h3 id={tituloId}>{titulo}</h3>
      <div className="confirm-cuerpo">{children}</div>
      <div className="confirm-acciones">
        <button
          type="button"
          className="btn btn-ghost"
          disabled={busy}
          onClick={onCancelar}
        >
          {textoCancelar}
        </button>
        <button
          type="button"
          className={"btn " + (peligro ? "btn-danger" : "btn-primary")}
          disabled={busy || deshabilitado}
          onClick={onConfirmar}
          autoFocus
        >
          {busy ? "Procesando…" : textoConfirmar}
        </button>
      </div>
    </dialog>
  );
}
