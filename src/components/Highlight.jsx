import React from "react";
import { norm } from "../lib/format";

export default function Highlight({ text, query }) {
  const t = text || "";
  const q = (query || "").trim();
  if (!q) return <>{t}</>;
  const i = norm(t).indexOf(norm(q));
  if (i < 0) return <>{t}</>;
  return (
    <>
      {t.slice(0, i)}
      <mark>{t.slice(i, i + q.length)}</mark>
      {t.slice(i + q.length)}
    </>
  );
}
