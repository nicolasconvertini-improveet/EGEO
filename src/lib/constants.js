export const ACTS = [
  { key: "inyectado", label: "Inyectado" },
  { key: "rebabado", label: "Rebabado" },
  { key: "armado", label: "Armado" },
  { key: "embolsado", label: "Embolsado" },
];

export const actLabel = (k) => ACTS.find((a) => a.key === k)?.label || k;

export const ROLES = {
  admin: {
    full: "Administrador",
    tabs: ["tablero", "registrar", "pedidos", "tareas", "mantenimiento", "articulos", "usuarios"],
  },
  supervisor: {
    full: "Supervisor",
    tabs: ["tablero", "registrar", "pedidos", "tareas", "mantenimiento"],
  },
  operario: { full: "Operario", tabs: ["registrar"] },
};

export const rango = (r) => ({ admin: 3, supervisor: 2, operario: 1 })[r] || 0;

export const OBJETIVO = 100;
