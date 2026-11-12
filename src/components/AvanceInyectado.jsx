import { formatearKg } from "../lib/montaje";
import React from "react";
import { avanceInyectado } from "../lib/inyectado";
import { nf } from "../lib/format";
export default function AvanceInyectado({ pedido, resultados = [] }) {
  if (!pedido)
    return (
      <p className="card" role="alert">
        No se pudo cargar el avance de la orden. Actualizá la pantalla.
      </p>
    );
  const a = avanceInyectado(pedido, resultados);
  return (
    <section
      className="card avance-inyectado"
      aria-label="Avance de la orden de inyectado"
    >
      <div className="sec-title">Avance de la orden · Inyectado</div>
      <p>
        Molde {pedido.configuracion?.codigo} · Máquina{" "}
        {pedido.configuracion?.maquina_codigo || "—"}
      </p>
      <p>Material: {pedido.configuracion?.material || "No informado"}</p>
      <dl className="avance-inyectado-totales">
        {[
          ["Ciclos solicitados", a.ciclosSolicitados],
          ["Ciclos pendientes", a.ciclosPendientes],
          ["Unidades solicitadas", nf(a.unidadesSolicitadas) + " u."],
          ["Unidades pendientes", nf(a.unidadesPendientes) + " u."],
          ["Material solicitado", formatearKg(a.gramosSolicitados)],
          ["Material pendiente estimado", formatearKg(a.gramosPendientes)],
        ].map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd className="mono">{v}</dd>
          </div>
        ))}
      </dl>
      {a.articulos.map((x) => (
        <div className="avance-inyectado-articulo" key={x.articulo_id}>
          <strong>
            {x.codigo} · {x.nombre}
          </strong>
          <p>
            Solicitadas: {nf(x.solicitado)} u. · Pendientes: {nf(x.pendiente)}{" "}
            u.
          </p>
          <small>
            Registradas: {nf(x.ok)} OK · {nf(x.scrap)} scrap
          </small>
        </div>
      ))}
      {resultados.length > 0 && (
        <p className="s">
          Avance estimado incluyendo las cantidades cargadas en esta tarea.
        </p>
      )}
      <small>
        El material pendiente se estima para completar las piezas OK. El scrap
        puede requerir material adicional. La colada ya está incluida en el
        consumo.
      </small>
    </section>
  );
}
