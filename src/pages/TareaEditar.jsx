import React, { useCallback, useEffect, useState } from "react";
import { Check, Trash2 } from "lucide-react";
import { actLabel } from "../lib/constants";
import { nf, fmtClock, fmtDT, toInputDT, fromInputDT } from "../lib/format";
import {
  fetchPausasTarea,
  fetchMotivosTodos,
  adminEditarTarea,
  adminEliminarTarea,
  adminEditarPausa,
  adminEliminarPausa,
} from "../api";
import ResultadosMolde from "../components/ResultadosMolde";
import ConfirmDialog from "../components/ConfirmDialog";

/* Pantalla de administrador: corregir o eliminar una tarea ya registrada y sus pausas.
   Toda la validación real la hace la base (migración 18) y queda auditada. */
export default function TareaEditar({
  tars,
  detail,
  notify,
  setDetail,
  reloadTars,
  reloadPeds,
}) {
  const t = tars.find((x) => x.id === detail?.id);

  const [form, setForm] = useState(() =>
    t
      ? {
          inicio: toInputDT(t.inicio),
          fin: toInputDT(t.fin),
          ok: String(t.ok),
          scrap: String(t.scrap),
          observaciones: t.observaciones,
        }
      : null,
  );
  const [resultados, setResultados] = useState(
    () =>
      t?.resultados.map((r) => ({
        articulo_id: r.articulo_id,
        piezas_ok: r.piezas_ok,
        piezas_scrap: r.piezas_scrap,
      })) || [],
  );
  const [motivo, setMotivo] = useState("");
  const [pausas, setPausas] = useState(null);
  const [motivos, setMotivos] = useState([]);
  const [busy, setBusy] = useState(false);
  const [confirmar, setConfirmar] = useState(null); // { tipo: "tarea" } | { tipo: "pausa", pausa }

  const cargarPausas = useCallback(() => {
    if (!t?.id) return;
    return fetchPausasTarea(t.id)
      .then((l) =>
        setPausas(
          l.map((p) => ({
            ...p,
            _inicio: toInputDT(p.inicio),
            _fin: toInputDT(p.fin),
            _motivoId: p.motivo_id,
          })),
        ),
      )
      .catch(() => {
        setPausas([]);
        notify("No se pudieron cargar las pausas", true);
      });
  }, [t?.id, notify]);

  useEffect(() => {
    cargarPausas();
    fetchMotivosTodos()
      .then(setMotivos)
      .catch(() => setMotivos([]));
  }, [cargarPausas]);

  if (!t || !form)
    return (
      <div className="card" role="alert">
        La tarea no está en la lista cargada (puede ser anterior a 60 días o ya
        fue eliminada).
      </div>
    );

  const set = (k, v) => setForm((s) => ({ ...s, [k]: v }));
  const motivoOk = motivo.trim().length >= 3;
  const totalSeg =
    form.inicio && form.fin
      ? (new Date(form.fin) - new Date(form.inicio)) / 1000
      : 0;
  const pausaSeg = (pausas || []).reduce(
    (s, p) =>
      s + Math.max(0, (new Date(p._fin) - new Date(p._inicio)) / 1000 || 0),
    0,
  );
  const errorForm =
    !form.inicio || !form.fin
      ? "Completá inicio y fin."
      : totalSeg <= 0
        ? "El fin debe ser posterior al inicio."
        : form.ok === "" || form.scrap === ""
          ? "Completá las cantidades."
          : "";

  const correr = async (fn, msg) => {
    setBusy(true);
    try {
      await fn();
      await Promise.all([reloadTars(), reloadPeds()]);
      notify(msg);
      return true;
    } catch (e) {
      notify(e.message, true);
      return false;
    } finally {
      setBusy(false);
    }
  };

  const guardarTarea = () =>
    correr(
      () =>
        adminEditarTarea(t, {
          inicio: fromInputDT(form.inicio),
          fin: fromInputDT(form.fin),
          ok: form.ok,
          scrap: form.scrap,
          observaciones: form.observaciones,
          motivo: motivo.trim(),
          resultados,
        }),
      "Tarea actualizada",
    );

  const guardarPausa = async (p) => {
    const ok = await correr(
      () =>
        adminEditarPausa(p.id, {
          inicio: fromInputDT(p._inicio),
          fin: fromInputDT(p._fin),
          motivoId: p._motivoId,
          motivo: motivo.trim(),
        }),
      "Pausa actualizada",
    );
    if (ok) cargarPausas();
  };

  const confirmarBaja = async () => {
    if (confirmar.tipo === "tarea") {
      const ok = await correr(
        () => adminEliminarTarea(t, motivo.trim()),
        "Tarea eliminada",
      );
      setConfirmar(null);
      if (ok) setDetail(null);
    } else {
      const ok = await correr(
        () => adminEliminarPausa(confirmar.pausa.id, motivo.trim()),
        "Pausa eliminada",
      );
      setConfirmar(null);
      if (ok) cargarPausas();
    }
  };

  const setPausa = (id, k, v) =>
    setPausas((l) => l.map((p) => (p.id === id ? { ...p, [k]: v } : p)));

  return (
    <>
      <div className="card">
        <div className="mono" style={{ fontSize: 12, color: "var(--ink2)" }}>
          {t.pedidoCodigo} · {actLabel(t.actividad)}
        </div>
        <div style={{ fontSize: 17, fontWeight: 700, marginTop: 2 }}>
          {t.articuloNombre}
        </div>
        <div style={{ fontSize: 12.5, color: "var(--ink2)", marginTop: 4 }}>
          Operario: {t.operario}
        </div>
      </div>

      <div className="field" style={{ marginTop: 14 }}>
        <label htmlFor="motivo-edicion">
          Motivo de la corrección <span className="req">*</span>
        </label>
        <input
          id="motivo-edicion"
          value={motivo}
          maxLength={500}
          placeholder="Ej.: el operario cargó mal las piezas OK"
          onChange={(e) => setMotivo(e.target.value)}
        />
        <small>
          Obligatorio para guardar o eliminar. Queda registrado en la auditoría.
        </small>
      </div>

      <div className="sec-title" style={{ marginTop: 18 }}>
        Datos de la tarea
      </div>
      <div className="card">
        <div className="fgrid2">
          <div className="field">
            <label htmlFor="ed-inicio">Inicio</label>
            <input
              id="ed-inicio"
              type="datetime-local"
              step="1"
              value={form.inicio}
              onChange={(e) => set("inicio", e.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor="ed-fin">Fin</label>
            <input
              id="ed-fin"
              type="datetime-local"
              step="1"
              value={form.fin}
              onChange={(e) => set("fin", e.target.value)}
            />
          </div>
          {!t.moldeId && (
            <>
              <div className="field">
                <label htmlFor="ed-ok">Piezas OK</label>
                <input
                  id="ed-ok"
                  inputMode="numeric"
                  value={form.ok}
                  onChange={(e) => set("ok", e.target.value.replace(/\D/g, ""))}
                />
              </div>
              <div className="field">
                <label htmlFor="ed-scrap">Scrap</label>
                <input
                  id="ed-scrap"
                  inputMode="numeric"
                  value={form.scrap}
                  onChange={(e) =>
                    set("scrap", e.target.value.replace(/\D/g, ""))
                  }
                />
              </div>
            </>
          )}
        </div>
        {t.moldeId && (
          <ResultadosMolde
            articulos={t.resultados}
            resultados={resultados}
            onChange={setResultados}
            disabled={busy}
          />
        )}
        <div className="field">
          <label htmlFor="ed-obs">Observaciones</label>
          <textarea
            id="ed-obs"
            rows={3}
            maxLength={2000}
            value={form.observaciones}
            onChange={(e) => set("observaciones", e.target.value)}
          />
        </div>
        <div
          className="s mono"
          style={{ fontSize: 12, color: "var(--ink2)", marginTop: 8 }}
        >
          Total {fmtClock(totalSeg)} · Pausas {fmtClock(pausaSeg)} · Neto{" "}
          {fmtClock(totalSeg - pausaSeg)}
        </div>
        {errorForm && <div className="hint-err">{errorForm}</div>}
        <button
          className="btn btn-primary"
          style={{ marginTop: 12 }}
          disabled={busy || !!errorForm || !motivoOk}
          onClick={guardarTarea}
        >
          <Check size={16} /> Guardar cambios de la tarea
        </button>
      </div>

      <div className="sec-title" style={{ marginTop: 18 }}>
        Pausas
      </div>
      {pausas === null ? (
        <div className="card" style={{ textAlign: "center" }}>
          <div className="spinner" style={{ margin: "0 auto" }} />
        </div>
      ) : pausas.length === 0 ? (
        <div className="card" style={{ fontSize: 13, color: "var(--ink2)" }}>
          La tarea no tiene pausas.
        </div>
      ) : (
        pausas.map((p) => (
          <div className="card pausa-edit" key={p.id}>
            <div className="fgrid2">
              <div className="field">
                <label>Inicio</label>
                <input
                  type="datetime-local"
                  step="1"
                  value={p._inicio}
                  onChange={(e) => setPausa(p.id, "_inicio", e.target.value)}
                />
              </div>
              <div className="field">
                <label>Fin</label>
                <input
                  type="datetime-local"
                  step="1"
                  value={p._fin}
                  onChange={(e) => setPausa(p.id, "_fin", e.target.value)}
                />
              </div>
            </div>
            <div className="field">
              <label>Motivo de parada</label>
              <select
                value={p._motivoId}
                onChange={(e) => setPausa(p.id, "_motivoId", e.target.value)}
              >
                {motivos.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.nombre}
                    {m.activo ? "" : " (inactivo)"}
                  </option>
                ))}
              </select>
            </div>
            <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
              <button
                className="btn btn-ghost"
                disabled={busy || !motivoOk}
                onClick={() => setConfirmar({ tipo: "pausa", pausa: p })}
              >
                <Trash2 size={15} /> Eliminar
              </button>
              <button
                className="btn btn-primary"
                disabled={busy || !motivoOk || !p._inicio || !p._fin}
                onClick={() => guardarPausa(p)}
              >
                <Check size={15} /> Guardar pausa
              </button>
            </div>
          </div>
        ))
      )}

      <button
        className="btn btn-danger"
        style={{ marginTop: 22 }}
        disabled={busy || !motivoOk}
        onClick={() => setConfirmar({ tipo: "tarea" })}
      >
        <Trash2 size={16} /> Eliminar tarea
      </button>

      <ConfirmDialog
        abierto={!!confirmar}
        titulo={
          confirmar?.tipo === "tarea"
            ? "¿Eliminar la tarea?"
            : "¿Eliminar la pausa?"
        }
        textoConfirmar="Eliminar"
        peligro
        busy={busy}
        onCancelar={() => setConfirmar(null)}
        onConfirmar={confirmarBaja}
      >
        {confirmar?.tipo === "tarea" ? (
          <p>
            Se elimina la tarea de {t.operario} ({fmtDT(t.inicio)} →{" "}
            {fmtDT(t.fin)}, {nf(t.ok)} OK) con todas sus pausas, y se recalcula
            el avance de la orden. No se puede deshacer.
          </p>
        ) : (
          confirmar && (
            <p>
              Pausa “{confirmar.pausa.motivo}” de{" "}
              {fmtDT(confirmar.pausa.inicio)} a {fmtDT(confirmar.pausa.fin)}. El
              tiempo pasa a contar como operativo.
            </p>
          )
        )}
      </ConfirmDialog>
    </>
  );
}
