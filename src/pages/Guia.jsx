import React, { useState } from "react";
import { ChevronDown, PlayCircle, ClipboardList, Package, Boxes, LayoutDashboard, Users, HelpCircle } from "lucide-react";

/* Nivel mínimo de rol que puede ver cada sección (rango: operario 1, supervisor 2, admin 3) */
const rango = (r) => ({ admin: 3, supervisor: 2, operario: 1 })[r] || 0;

const SECCIONES = [
  {
    id: "exportar",
    min: 3,
    icon: ClipboardList,
    titulo: "Exportar datos a Excel",
    resumen: "Descargá tablas completas desde el botón de descarga de la cabecera.",
    bloques: [
      [
        "Descargas",
        "Cada botón genera un Excel independiente de tarea_pausas, tareas, articulos o pedidos. Incluye todas las filas y columnas, sin filtros.",
      ],
      [
        "Contenido",
        "Se incluyen tareas sin confirmar, pausas abiertas, artículos inactivos y órdenes finalizadas. La hoja Exportacion indica la cantidad de registros y la fecha de lectura.",
      ],
      [
        "Formato",
        "Las fechas y los decimales se conservan como texto para mantener su precisión. Los valores nulos aparecen como celdas vacías.",
      ],
    ],
  },
  {
    id: "registrar",
    min: 1,
    icon: PlayCircle,

    titulo: "Registrar una tarea",
    resumen: "Iniciá, pausá o finalizá y registrá las cantidades y observaciones.",
    bloques: [
      [
        "1 · Iniciar",
        "Elegí la orden (podés buscarlo por código o artículo) y el proceso. Tocá “Iniciar tarea” cuando arranques. Desde ese momento la orden y el proceso quedan fijos.",
      ],
      [
        "2 · Trabajar",
        "El contador total sigue avanzando. Podés pausar con motivo, reanudar o finalizar incluso desde una pausa. Cada pausa se guarda como tiempo no operativo y se resta del total para calcular la eficiencia. No podés iniciar otra tarea hasta registrar la actual, aunque esté pausada. Al volver a la app se recupera su estado.",
      ],
      [
        "3 · Cargar piezas",
        "Al finalizar, cargá las Piezas OK, el Scrap y las observaciones sobre problemas que alteraron el tiempo. La eficiencia usa el tiempo operativo neto. Si no hubo producción, registrá cero piezas y explicá el motivo.",
      ],
      [
        "Resultado",
        "Con “Registrar tarea” se guarda y suma a la orden. Si te equivocaste al iniciar, registrá cero piezas y explicalo en observaciones para conservar el tiempo y las pausas.",
      ],
    ],
  },
  {
    id: "pedidos",
    min: 2,
    icon: ClipboardList,
    titulo: "Órdenes",
    resumen: "Creá órdenes de fabricación y seguí su avance.",
    bloques: [
      ["Crear", "“Nueva orden”: código (obligatorio y único), artículo activo y cantidad a fabricar."],
      ["Estados", "Pendiente (sin producción), En curso (con avance) y Finalizada (todas las etapas llegaron a la cantidad pedida)."],
      [
        "Avance por etapa",
        "Una pieza se considera completa cuando pasó por todas las etapas que el artículo requiere. El avance es el de la etapa más atrasada.",
      ],
      ["Detalle", "Muestra los totales por etapa (inyectado, rebabado, armado, embolsado) y el historial de tareas de la orden."],
    ],
  },
  {
    id: "tareas",
    min: 2,
    icon: Boxes,
    titulo: "Historial de tareas",
    resumen: "Consultá y filtrá todo lo registrado.",
    bloques: [
      ["Filtros", "Por fecha (desde/hasta), proceso, usuario y orden. Se combinan entre sí y hay un total de piezas al pie."],
      ["Lectura", "Cada línea muestra la eficiencia (el número de color), el horario, las piezas OK y el responsable."],
    ],
  },

  {
    id: "tablero",
    min: 2,
    icon: LayoutDashboard,
    titulo: "Tablero de control",
    resumen: "Indicadores de desempeño de la operación.",
    bloques: [
      ["Situación actual", "Órdenes y tareas en curso en este momento."],
      ["Día vencido", "El resto muestra la jornada anterior completa: unidades, productividad, tiempo estimado y scrap."],
      ["Real vs objetivo", "Compara la productividad con el objetivo de 100 % (cumplir el tiempo estándar)."],
      ["Operarios y evolución", "Producción por persona y tendencia de los últimos 7 días."],
    ],
  },
  {
    id: "articulos",
    min: 3,
    icon: Package,
    titulo: "Artículos",
    resumen: "El maestro de productos y sus tiempos estándar.",
    bloques: [
      ["Datos", "Código (único) y nombre son obligatorios; molde, máquina, bocas y material son opcionales."],
      [
        "Tiempos estándar",
        "Segundos por unidad de cada proceso. Si un artículo no pasa por una etapa, se deja en cero y esa etapa no cuenta para completarlo.",
      ],
      [
        "Activar / inactivar",
        "Los artículos no se borran: se inactivan para conservar el historial. Un inactivo no aparece al crear órdenes y se puede reactivar.",
      ],
    ],
  },

  {
    id: "usuarios",
    min: 3,
    icon: Users,
    titulo: "Usuarios",
    resumen: "Alta de cuentas y asignación de roles.",
    bloques: [
      ["Crear", "Nombre, e-mail, contraseña inicial (mín. 6) y rol. La cuenta queda habilitada al instante."],
      ["Roles", "Operario (registra tareas), Supervisor (además órdenes y tablero) y Administrador (todo). Se cambian con un toque."],
      ["Activar / desactivar", "Podés dar de baja a alguien sin borrar su historial. No podés cambiar tu propio rol ni desactivarte."],
    ],
  },
];

const FAQ = [
  [
    "¿Pueden trabajar varios operarios a la vez?",
    "Sí, cada uno con su propia cuenta y una tarea pendiente como máximo. Pueden trabajar sobre la misma orden o actividad; cada uno registra únicamente sus propias piezas.",
  ],
  ["Cerré la app con una tarea abierta, ¿se perdió?", "No. La tarea se guarda al iniciarse; al volver a entrar aparece para finalizarla."],
  [
    "¿Puedo tener dos tareas abiertas?",
    "No. Hay que finalizar y registrar las cantidades de la actual antes de empezar otra. Una pausa mantiene reservada la tarea.",
  ],
  [
    "La productividad dio un valor raro",
    "Suele indicar que el tiempo estándar del artículo no refleja la realidad. Revisalo con un administrador.",
  ],
  [
    "El tablero no muestra hoy",
    "Es a propósito: trabaja a día vencido y muestra la jornada anterior. Los indicadores “en curso” sí son del momento.",
  ],
];

function Item({ icon: Icon, titulo, resumen, children }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="gsec">
      <button className="ghead" onClick={() => setOpen((v) => !v)}>
        <span className="gic">
          <Icon size={18} />
        </span>
        <span className="gtt">
          <span className="gt">{titulo}</span>
          <span className="gr">{resumen}</span>
        </span>
        <ChevronDown size={18} className={"gchev" + (open ? " op" : "")} />
      </button>
      {open && <div className="gbody">{children}</div>}
    </div>
  );
}

export default function Guia({ rol }) {
  const nivel = rango(rol);
  const visibles = SECCIONES.filter((s) => nivel >= s.min);

  return (
    <>
      <div className="dash-note" style={{ marginTop: 0 }}>
        <HelpCircle size={16} />
        <span>Guía de uso — se muestran las funciones habilitadas para tu rol.</span>
      </div>

      {visibles.map((s) => (
        <Item key={s.id} icon={s.icon} titulo={s.titulo} resumen={s.resumen}>
          {s.bloques.map(([t, d], i) => (
            <div className="gblock" key={i}>
              <div className="gbt">{t}</div>
              <div className="gbd">{d}</div>
            </div>
          ))}
        </Item>
      ))}

      <Item icon={HelpCircle} titulo="Preguntas frecuentes" resumen="Dudas comunes y su respuesta.">
        {FAQ.map(([q, a], i) => (
          <div className="gblock" key={i}>
            <div className="gbt">{q}</div>
            <div className="gbd">{a}</div>
          </div>
        ))}
      </Item>
    </>
  );
}
