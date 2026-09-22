import React from "react";
import { ChevronLeft, LogOut, HelpCircle, LayoutDashboard, Package, ClipboardList, Timer, Boxes, Users, Download } from "lucide-react";
import { supabase } from "../supabaseClient";
import { ROLES } from "../lib/constants";
import { findArt, findPed } from "../lib/format";

export default function AppBar({ rol, tab, detail, arts, peds, onBack, onGuia, onExportar }) {
  let title = tabLabel(tab),
    sub = null,
    back = false;
  if (detail?.type === "art") {
    const a = findArt(arts, detail.id);
    title = a?.nombre || "Artículo";
    sub = a?.codigo;
    back = true;
  } else if (detail?.type === "artNew") {
    title = detail.edit ? "Editar artículo" : "Nuevo artículo";
    back = true;
  } else if (detail?.type === "ped") {
    const p = findPed(peds, detail.id);
    title = p?.codigo || "Orden";
    sub = p?.articuloNombre;
    back = true;
  } else if (detail?.type === "pedNew") {
    title = "Nueva orden";
    back = true;
  } else if (detail?.type === "usrNew") {
    title = "Nuevo usuario";
    back = true;
  } else if (detail?.type === "guia") {
    title = "Guía de uso";
    back = true;
  } else if (detail?.type === "exportar") {
    title = "Exportar";
    back = true;
  } else if (tab === "tablero") sub = "Desempeño de la operación";

  return (
    <div className="appbar">
      <div className="row">
        <div style={{ minWidth: 0 }}>
          {back && (
            <button className="linkback" onClick={onBack}>
              <ChevronLeft size={16} /> Volver
            </button>
          )}
          <h1
            style={{
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {title}
          </h1>
          {sub && <div className="sub">{sub}</div>}
        </div>
        <div
          style={{
            display: "flex",
            gap: 8,
            alignItems: "center",
            flex: "none",
          }}
        >
          <span className="chip-role">{ROLES[rol].full}</span>
          {rol === "admin" && (
            <button className="iconbtn" title="Exportar datos" aria-label="Exportar datos" onClick={onExportar}>
              <Download size={17} />
            </button>
          )}
          <button className="iconbtn" title="Guía de uso" onClick={onGuia}>
            <HelpCircle size={17} />
          </button>
          <button className="iconbtn" title="Salir" onClick={() => supabase.auth.signOut()}>
            <LogOut size={17} />
          </button>
        </div>
      </div>
      <div className="hazard" />
    </div>
  );
}

export function tabIcon(t) {
  const s = 19;
  if (t === "tablero") return <LayoutDashboard size={s} />;
  if (t === "articulos") return <Package size={s} />;
  if (t === "pedidos") return <ClipboardList size={s} />;
  if (t === "tareas") return <Boxes size={s} />;
  if (t === "usuarios") return <Users size={s} />;
  return <Timer size={s} />;
}

export const tabLabel = (t) =>
  ({
    tablero: "Tablero",
    articulos: "Artículos",
    pedidos: "Órdenes",
    tareas: "Tareas",
    registrar: "Registrar",
    usuarios: "Usuarios",
  })[t];
