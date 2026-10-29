export const ESTADOS_TRABAJO = [
  { key: "pendiente", label: "Pendiente de asignación" },
  { key: "asignada", label: "Asignada" },
  { key: "en_curso", label: "En curso" },
  { key: "resuelta", label: "Resuelta" },
];
export const estadoTrabajoLabel = (estado) =>
  ESTADOS_TRABAJO.find((e) => e.key === estado)?.label || estado;
export function tarjetasTrabajos(solicitudes) {
  return ["mantenimiento", "molienda"].flatMap((tipo) =>
    ESTADOS_TRABAJO.map((estado) => ({
      tipo,
      estado: estado.key,
      label: estado.label,
      cantidad: solicitudes.filter(
        (s) => s.tipo === tipo && s.estado === estado.key,
      ).length,
    })),
  );
}
export function filtrarTrabajos(
  solicitudes,
  { estado = "sin_resolver", tipo = "", asignado = "", destino = "" } = {},
) {
  return solicitudes.filter(
    (s) =>
      (estado === "todos" ||
        (estado === "sin_resolver"
          ? s.estado !== "resuelta"
          : s.estado === estado)) &&
      (!tipo || s.tipo === tipo) &&
      (!asignado || s.asignado_id === asignado) &&
      (!destino || (s.maquina_id || s.equipo_id) === destino),
  );
}
