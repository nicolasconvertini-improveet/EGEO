import React, { useState } from "react";
import { ArrowRight, Eye, EyeOff } from "lucide-react";
import { supabase } from "../supabaseClient";

export default function Login() {
  const [mode, setMode] = useState("in");
  const [email, setEmail] = useState("");
  const [pass, setPass] = useState("");
  const [verPass, setVerPass] = useState(false);
  const [nombre, setNombre] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  const submit = async () => {
    setErr("");
    setBusy(true);
    try {
      if (mode === "in") {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password: pass,
        });
        if (error) throw error;
      } else {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password: pass,
          options: { data: { nombre: nombre.trim() } },
        });
        if (error) throw error;
        if (!data.session) {
          setErr("Cuenta creada. Revisá tu correo para confirmarla y luego ingresá.");
          setMode("in");
        }
      }
    } catch (e) {
      setErr(e?.message === "Invalid login credentials" ? "Usuario o contraseña incorrectos." : e?.message || "No se pudo continuar.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="login">
      <img src="/logo.png" alt="Improveet" className="brand" />
      <h1>OMS</h1>
      <h2>Operations Management System</h2>
      <p>Registro de tareas y productividad de planta.</p>
      {err && <div className="lerr">{err}</div>}
      {mode === "up" && (
        <div className="lf">
          <input placeholder="Nombre y apellido" value={nombre} onChange={(e) => setNombre(e.target.value)} />
        </div>
      )}
      <div className="lf">
        <input placeholder="E-mail" type="email" autoCapitalize="none" value={email} onChange={(e) => setEmail(e.target.value)} />
      </div>
      <div className="lf lf-pass">
        <input
          placeholder="Contraseña"
          type={verPass ? "text" : "password"}
          autoComplete={mode === "in" ? "current-password" : "new-password"}
          value={pass}
          onChange={(e) => setPass(e.target.value)}
        />
        <button
          type="button"
          className="ver-pass"
          aria-label={verPass ? "Ocultar contraseña" : "Mostrar contraseña"}
          aria-pressed={verPass}
          onClick={() => setVerPass((v) => !v)}
        >
          {verPass ? <EyeOff size={18} /> : <Eye size={18} />}
        </button>
      </div>
      <button className="btn btn-primary" style={{ marginTop: 8 }} disabled={busy || !email || !pass} onClick={submit}>
        {mode === "in" ? "Ingresar" : "Crear cuenta"} <ArrowRight size={17} strokeWidth={2.4} />
      </button>
      <div className="switch-mode">
        {mode === "in" ? (
          <>
            ¿No tenés cuenta?{" "}
            <button
              onClick={() => {
                setMode("up");
                setErr("");
              }}
            >
              Crear una
            </button>
          </>
        ) : (
          <>
            ¿Ya tenés cuenta?{" "}
            <button
              onClick={() => {
                setMode("in");
                setErr("");
              }}
            >
              Ingresar
            </button>
          </>
        )}
      </div>
    </div>
  );
}
