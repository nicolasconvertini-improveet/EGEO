import React, { useState } from "react";
import {
  ChevronDown,
  PlayCircle,
  ClipboardList,
  Package,
  Boxes,
  LayoutDashboard,
  Users,
  HelpCircle,
  Wrench,
} from "lucide-react";

/* Nivel mínimo de rol que puede ver cada sección (rango: operario 1, supervisor 2, admin 3) */
const rango = (r) => ({ admin: 3, supervisor: 2, operario: 1 })[r] || 0;

const SECCIONES = [
  {
    id: "mantenimiento",
    min: 1,
    icon: Wrench,
    titulo: "Mantenimiento y molienda",
    resumen: "Consultá, asigná y resolvé solicitudes de trabajo.",
    bloques: [
      [
        "Solicitar",
        "En Trabajos, un administrador o supervisor solicita mantenimiento sobre una máquina/equipo, o una tarea de molienda. Molienda permite observaciones opcionales sin exigir detalle técnico.",
      ],
      [
        "Asignar",
        "Administrador y supervisor asignan o reasignan tareas a usuarios activos. El operario ve únicamente las que tiene asignadas.",
      ],
      [
        "Ejecutar y resolver",
        "Iniciá una tarea asignada y, al terminar, cargá los minutos. Para mantenimiento describí el trabajo realizado; para molienda hay un campo de observaciones opcional.",
      ],
      [
        "Pendientes",
        "Filtrá por estado, tipo, usuario o equipo. El tablero muestra un resumen de los pendientes. El reporte descarga el listado visible según tus permisos.",
      ],
      [
        "Historial",
        "Las solicitudes resueltas y las intervenciones antiguas se conservan para consulta. Las asignaciones y transiciones quedan auditadas.",
      ],
    ],
  },
  {
    id: "planta",
    min: 3,
    icon: Package,
    titulo: "Máquinas, moldes y materiales",
    resumen: "Administrá los recursos y artículos por ciclo.",
    bloques: [
      [
        "Planta",
        "Creá, editá y desactivá máquinas, equipos, moldes y materiales. Cada molde permite seleccionar varias máquinas compatibles, un material sugerido, consumo en gramos por ciclo, segundos por ciclo y uno o varios artículos con sus unidades por ciclo.",
      ],
      [
        "Materiales y colada",
        "Los materiales se administran con código, descripción y estado activo/inactivo. Completá el peso de colada del molde en gramos: es informativo y ya está incluido en el material por ciclo, por lo que no se suma otra vez. En moldes anteriores puede faltar este dato; completalo antes de crear una orden nueva.",
      ],
      [
        "Desactivación",
        "Los inactivos se conservan para consultar la historia. Para desactivar una máquina, primero desactivá o reasigná sus moldes activos.",
      ],
    ],
  },
  {
    id: "indicadores",
    min: 3,
    icon: LayoutDashboard,
    titulo: "Indicadores",
    resumen: "Tablas de producción y horas por motivo.",
    bloques: [
      [
        "Producción",
        "Consultá código de pieza, descripción, OK y scrap del período. Si incluís varios procesos, las cantidades suman operaciones.",
      ],
      [
        "Horas",
        "La tabla muestra horas por motivo y el total. Subida, calentamiento y bajada de molde figuran como tiempos no operativos, igual que las pausas, una sola vez por orden. Son minutos declarados atribuidos al usuario y a la fecha de carga. No se suman al tiempo productivo ni se descuentan nuevamente de una tarea. Mantenimiento y molienda incluyen toda la planta, sin depender de usuario, artículo o proceso.",
      ],
      [
        "Filtros y comparación",
        "Elegí período, artículos, proceso y usuario. Los filtros se pueden plegar. El resumen y la comparación agrupada conservan sus opciones originales.",
      ],
    ],
  },
  {
    id: "exportar",
    min: 3,
    icon: ClipboardList,
    titulo: "Exportar datos a Excel",
    resumen:
      "Descargá tablas completas desde el botón de descarga de la cabecera.",
    bloques: [
      [
        "Descargas",
        "Cada botón genera un Excel de mantenimientos, pausas, tareas o artículos. Las tareas de molde tienen una fila por artículo. Trabajos e Indicadores ofrecen sus propias descargas filtradas.",
      ],
      [
        "Contenido",
        "El reporte de tareas incluye las confirmadas; el maestro de artículos incluye inactivos. Pausas incluye además subida, calentamiento y bajada de molde. Para estos tiempos declarados, inicio indica la fecha de carga y fin queda vacío. La hoja Exportacion indica cantidad de registros y fecha de lectura.",
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
    resumen:
      "Iniciá, pausá o finalizá y registrá las cantidades y observaciones.",
    bloques: [
      [
        "1 · Iniciar",
        "Elegí la orden (podés buscarla por código o artículo) y el proceso. En la primera toma de una orden nueva de inyectado, tocá “Tomar orden y subir molde”, confirmá que vas a tomarla y subir el molde, y cargá los minutos de subida y calentamiento antes de iniciar producción. Los campos son obligatorios; si un tiempo no aplica, ingresá 0 explícitamente. Para los otros procesos, tocá “Iniciar tarea”. Desde el inicio, la orden y el proceso quedan fijos.",
      ],
      [
        "Retomar inyectado",
        "Si una tarea termina sin completar las cantidades de la orden, el molde permanece montado. Al retomar, incluso con otro operario o dispositivo, no se repiten la confirmación de subida ni los tiempos de subida y calentamiento. Tampoco se pide bajada ni limpieza al terminar una tarea parcial. No registres los tiempos de montaje también como una pausa de producción.",
      ],
      [
        "2 · Trabajar",
        "El contador total sigue avanzando. Podés pausar con motivo, reanudar o finalizar incluso desde una pausa. Cada pausa se guarda como tiempo no operativo y se resta del total para calcular la eficiencia. No podés iniciar otra tarea hasta registrar la actual, aunque esté pausada. Al ingresar nuevamente a Registrar se recupera su estado. Cambiar de ventana no recarga los datos.",
      ],
      [
        "3 · Cargar piezas",
        "Al finalizar, cargá las Piezas OK, el Scrap y las observaciones sobre problemas que alteraron el tiempo. La eficiencia usa el tiempo operativo neto. Si no hubo producción, registrá cero piezas y explicá el motivo.",
      ],
      [
        "Resultado",
        "Con “Registrar tarea” se guarda y suma a la orden. Si te equivocaste al iniciar, registrá cero piezas y explicalo en observaciones para conservar el tiempo y las pausas. En inyectado, la productividad se calcula por ciclos ejecutados sobre el tiempo operativo neto; los tiempos declarados del molde quedan separados.",
      ],
      [
        "Cerrar una orden de inyectado",
        "Cuando todos los artículos alcanzan su objetivo OK y no quedan tareas abiertas o por confirmar, registrá los minutos de bajada y confirmá “Recordá limpiar el molde”. El cierre está disponible en Registrar y en el detalle de la orden. Es obligatorio para cerrar las órdenes nuevas de inyectado y no se vuelve a pedir una vez registrado. Lo realiza un operario que participó en la orden, un supervisor o un administrador.",
      ],
    ],
  },
  {
    id: "pedidos",
    min: 1,
    icon: ClipboardList,
    titulo: "Órdenes",
    resumen: "Cada orden nueva corresponde a un proceso.",
    bloques: [
      [
        "Crear",
        "Completá un código único y elegí un proceso. Para inyectado seleccioná un molde, una de sus máquinas compatibles activas y el material: se sugiere el del molde, pero tenés que confirmarlo o elegir otro y confirmarlo. Se incluyen todos los artículos del molde. Para los demás procesos seleccioná un artículo activo con estándar habilitado.",
      ],
      [
        "Cantidades",
        "En inyectado cargá ciclos previstos: el objetivo de cada artículo es ciclos × unidades por ciclo. Para otros procesos cargá la cantidad de piezas.",
      ],
      [
        "Registrar producción",
        "El proceso queda fijado por la orden. Al finalizar inyectado se cargan piezas OK y rechazo por cada artículo del molde. Su suma debe ser múltiplo de las unidades por ciclo, y todos deben informar los mismos ciclos. La productividad usa ciclos ejecutados y el avance muestra unidades, el material elegido y kilos solicitados y pendientes. Las cantidades se guardan juntas.",
      ],
      [
        "Avance",
        "La producción de inyectado se completa cuando todos los artículos alcanzan sus objetivos OK. La orden queda pendiente de bajada y limpieza hasta registrar ese cierre; no se puede iniciar otra tarea de producción en ella. El avance muestra ciclos equivalentes según el artículo con menor avance relativo. Los kilos pendientes estiman el material necesario para completar las piezas OK y no representan stock disponible. El resto de órdenes considera únicamente su proceso.",
      ],
      [
        "Configuración histórica",
        "La orden guarda la configuración usada: máquina, material, artículos y estándares. Editar los catálogos no cambia esos datos históricos. Las órdenes creadas antes de esta actualización conservan su circuito anterior y no se les inventan tiempos de montaje.",
      ],
      [
        "Estados y correcciones",
        "El administrador puede cambiar estados según el circuito de la orden. Supervisor y administrador pueden editar la cantidad objetivo sin reducirla por debajo de lo ya producido. En una orden nueva de inyectado no se puede omitir la bajada y limpieza ni volver a producir después de retirar el molde: para otro montaje corresponde una nueva orden. Los cambios quedan auditados.",
      ],
    ],
  },
  {
    id: "tareas",
    min: 2,
    icon: Boxes,
    titulo: "Historial de tareas",
    resumen: "Consultá y filtrá todo lo registrado.",
    bloques: [
      [
        "Filtros",
        "Por fecha (desde/hasta), proceso, usuario y orden. Se combinan entre sí y hay un total de piezas al pie.",
      ],
      [
        "Lectura",
        "Cada línea muestra la eficiencia (el número de color), el horario, las piezas OK y el responsable.",
      ],
    ],
  },

  {
    id: "tablero",
    min: 3,
    icon: LayoutDashboard,
    titulo: "Tablero de control",
    resumen: "Indicadores de desempeño de la operación.",
    bloques: [
      [
        "Situación actual",
        "Órdenes y tareas en curso. Se actualiza solo cada minuto mientras el tablero está abierto.",
      ],
      [
        "En vivo",
        "El resto muestra la jornada de hoy: unidades, productividad, tiempo estimado y scrap de las tareas ya registradas.",
      ],
      [
        "Real vs objetivo",
        "Compara la productividad con el objetivo de 100 % (cumplir el tiempo estándar).",
      ],
      [
        "Operarios y evolución",
        "Producción por persona y tendencia de los últimos 7 días.",
      ],
    ],
  },
  {
    id: "articulos",
    min: 3,
    icon: Package,
    titulo: "Artículos",
    resumen: "El maestro de productos y sus tiempos estándar.",
    bloques: [
      [
        "Datos",
        "Código (único) y nombre son obligatorios; molde, máquina, bocas y material son opcionales.",
      ],
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
      [
        "Crear",
        "Nombre, e-mail, contraseña inicial (mín. 6) y rol. La cuenta queda habilitada al instante.",
      ],
      [
        "Roles",
        "Operario (registra tareas), Supervisor (además órdenes y tablero) y Administrador (todo). Se cambian con un toque.",
      ],
      [
        "Cambiar contraseña",
        "Como administrador, podés cambiar la contraseña de otros usuarios, incluidos otros administradores. En su tarjeta tocá “Cambiar contraseña”, ingresá la nueva contraseña (entre 6 y 128 caracteres), repetila y tocá “Guardar contraseña”. Esperá la confirmación y compartila con esa persona por un medio seguro. Si aparece un requisito adicional de seguridad, elegí una contraseña más fuerte. Esta opción no aparece en tu propia tarjeta y no activa las cuentas desactivadas.",
      ],
      [
        "Activar / desactivar",
        "Podés dar de baja a alguien sin borrar su historial. No podés cambiar tu propio rol ni desactivarte.",
      ],
    ],
  },
];

const FAQ = [
  [
    "¿Cuándo se actualizan los datos?",
    "Al ingresar a cada pantalla o detalle. No hay recargas periódicas ni al volver a la ventana. Las acciones propias muestran su resultado y las descargas consultan los datos cuando las solicitás. El timer avanza localmente sin consultar la base.",
  ],
  [
    "¿Pueden trabajar varios operarios a la vez?",
    "Sí, cada uno con su propia cuenta y una tarea pendiente como máximo. Pueden trabajar sobre la misma orden o actividad; cada uno registra únicamente sus propias piezas.",
  ],
  [
    "Cerré la app con una tarea abierta, ¿se perdió?",
    "No. La tarea se guarda al iniciarse; al volver a entrar aparece para finalizarla.",
  ],
  [
    "¿Puedo tener dos tareas abiertas?",
    "No. Hay que finalizar y registrar las cantidades de la actual antes de empezar otra. Una pausa mantiene reservada la tarea.",
  ],
  [
    "La productividad dio un valor raro",
    "Revisá con un administrador el tiempo estándar del artículo o, en inyectado, los segundos por ciclo guardados en la orden. Subida, calentamiento y bajada se registran aparte y no deben cargarse también como pausas de producción.",
  ],
  [
    "El tablero no muestra hoy",
    "Es a propósito: trabaja a día vencido y muestra la jornada anterior. Los indicadores “en curso” muestran los datos obtenidos al ingresar al tablero.",
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
        <span>
          Guía de uso — se muestran las funciones habilitadas para tu rol.
        </span>
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

      <Item
        icon={HelpCircle}
        titulo="Preguntas frecuentes"
        resumen="Dudas comunes y su respuesta."
      >
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
