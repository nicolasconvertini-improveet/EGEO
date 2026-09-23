import React, { useEffect, useRef, useState } from "react";
import { Download } from "lucide-react";
import { cargarMantenimientos, guardarMantenimiento } from "../lib/mantenimientos";

function hoyLocal() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
const inicial = () => ({ ejecutor: "", fecha: hoyLocal(), detalle: "", preventivo: false, minutos: "" });
const ordenar = (a, b) =>
  b.fecha_ejecucion.localeCompare(a.fecha_ejecucion) || b.creado.localeCompare(a.creado) || a.id.localeCompare(b.id);

export default function Mantenimiento({ rol, perfil }) {
  const permitido = ["admin", "supervisor"].includes(rol);
  const [form, setForm] = useState(inicial);
  const [datos, setDatos] = useState(null);
  const [errorCarga, setErrorCarga] = useState("");
  const [reintento, setReintento] = useState(0);
  const [error, setError] = useState("");
  const [mensaje, setMensaje] = useState("");
  const [guardando, setGuardando] = useState(false);
  const [exportando, setExportando] = useState(false);
  const [pagina, setPagina] = useState(0);
  const intento = useRef(null);
  const ocupado = useRef(false);
  const descarga = useRef(null);
  const montado = useRef(false);

  useEffect(() => {
    montado.current = true;
    return () => {
      montado.current = false;
      descarga.current?.abort();
    };
  }, []);
  useEffect(() => {
    if (!permitido) return;
    const control = new AbortController();
    setErrorCarga("");
    cargarMantenimientos(control.signal)
      .then((res) => {
        if (!control.signal.aborted) setDatos(res);
      })
      .catch((e) => {
        if (!control.signal.aborted) setErrorCarga(e.message);
      });
    return () => control.abort();
  }, [permitido, reintento]);

  if (!permitido) return <div className="empty">Acceso para administradores y supervisores.</div>;
  if (errorCarga)
    return (
      <div className="card" role="alert">
        {errorCarga}
        <button className="btn btn-primary" onClick={() => setReintento((n) => n + 1)}>
          Reintentar
        </button>
      </div>
    );
  if (!datos) return <div role="status">Cargando mantenimientos…</div>;

  const cambiar = (campo, valor) => setForm((f) => ({ ...f, [campo]: valor }));
  const guardar = async (e) => {
    e.preventDefault();
    if (ocupado.current) return;
    if (!form.detalle.trim() || !Number.isInteger(Number(form.minutos)) || Number(form.minutos) <= 0) {
      setError("Completá el detalle y un tiempo en minutos enteros mayor que cero.");
      return;
    }
    ocupado.current = true;
    setGuardando(true);
    setError("");
    setMensaje("");
    // Mantener el identificador y contenido cuando no se recibió confirmación.
    const actual = intento.current || { id: crypto.randomUUID(), form: { ...form } };
    intento.current = actual;
    try {
      const registro = await guardarMantenimiento(actual.id, actual.form);
      if (!montado.current) return;
      setDatos((d) => ({ ...d, registros: [registro, ...d.registros.filter((r) => r.id !== registro.id)].sort(ordenar) }));
      intento.current = null;
      setForm(inicial());
      setPagina(0);
      setMensaje("Mantenimiento registrado.");
    } catch (err) {
      if (montado.current)
        setError(
          `${err.message} Reintentá el mismo envío. Si necesitás cambiarlo, salí y volvé a entrar; revisá primero si ya fue registrado.`,
        );
    } finally {
      ocupado.current = false;
      if (montado.current) setGuardando(false);
    }
  };

  const paginas = Math.max(1, Math.ceil(datos.registros.length / 20));
  return (
    <>
      <p>Registro de ejecución de tareas de mantenimiento.</p>
      <form className="card" onSubmit={guardar}>
        <div className="field">
          <label htmlFor="mant-registrante">Registrado por</label>
          <input id="mant-registrante" value={perfil.nombre || perfil.id} readOnly />
        </div>
        <fieldset disabled={guardando || intento.current !== null} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
          <div className="field">
            <label htmlFor="mant-ejecutor">Ejecutor</label>
            <select id="mant-ejecutor" required value={form.ejecutor} onChange={(e) => cambiar("ejecutor", e.target.value)}>
              <option value="">Seleccioná un usuario</option>
              {datos.usuarios.map((u) => (
                <option key={u.id} value={u.id}>
                  {u.nombre || "Sin nombre"} · {u.id.slice(0, 8)}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="mant-fecha">Fecha de ejecución</label>
            <input id="mant-fecha" type="date" required value={form.fecha} onChange={(e) => cambiar("fecha", e.target.value)} />
          </div>
          <div className="field">
            <label htmlFor="mant-detalle">Detalle de la tarea</label>
            <textarea
              id="mant-detalle"
              required
              maxLength={5000}
              rows={4}
              style={{ background: "#fff", width: "100%" }}
              value={form.detalle}
              onChange={(e) => cambiar("detalle", e.target.value)}
            />
          </div>
          <label style={{ display: "flex", gap: 10, alignItems: "center", margin: "16px 0" }}>
            <input type="checkbox" checked={form.preventivo} onChange={(e) => cambiar("preventivo", e.target.checked)} />
            Preventivo (sin marcar: correctivo)
          </label>
          <div className="field">
            <label htmlFor="mant-minutos">Tiempo de mantenimiento (minutos)</label>
            <input
              id="mant-minutos"
              type="number"
              required
              min="1"
              max="2147483647"
              step="1"
              inputMode="numeric"
              value={form.minutos}
              onChange={(e) => cambiar("minutos", e.target.value)}
            />
          </div>
        </fieldset>
        <button className="btn btn-primary" type="submit" style={{ marginTop: 12 }} disabled={guardando || !datos.usuarios.length}>
          {guardando ? "Guardando…" : intento.current ? "Reintentar guardado" : "Guardar mantenimiento"}
        </button>
      </form>
      {error && (
        <p className="hint-err" role="alert">
          {error}
        </p>
      )}
      <p role="status" aria-live="polite">
        {mensaje}
      </p>

      <h2 style={{ fontSize: 18 }}>Historial ({datos.registros.length})</h2>
      {!datos.registros.length && <p>No hay mantenimientos registrados.</p>}
      {datos.registros.slice(pagina * 20, (pagina + 1) * 20).map((r) => (
        <article className="card" key={r.id} style={{ marginBottom: 12 }}>
          <strong>
            {r.fecha_ejecucion.split("-").reverse().join("/")} ·{" "}
            {r.preventivo === true || r.preventivo === "true" ? "Preventivo" : "Correctivo"}
          </strong>
          <p style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{r.detalle}</p>
          <div>Ejecutor: {r.ejecutor_nombre || r.ejecutor_id}</div>
          <div>Registrado por: {r.registrado_nombre || r.registrado_por}</div>
          <div className="mono">{r.minutos} min</div>
        </article>
      ))}
      {paginas > 1 && (
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <button className="btn btn-ghost" disabled={pagina === 0} onClick={() => setPagina((p) => p - 1)}>
            Anterior
          </button>
          <span>
            {pagina + 1}/{paginas}
          </span>
          <button className="btn btn-ghost" disabled={pagina + 1 === paginas} onClick={() => setPagina((p) => p + 1)}>
            Siguiente
          </button>
        </div>
      )}
    </>
  );
}
