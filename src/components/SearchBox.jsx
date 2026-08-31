import React from "react";
import { Search } from "lucide-react";

export default function SearchBox({ value, onChange, placeholder }) {
  return (
    <div className="search">
      <Search size={17} color="#9AA2AB" />
      <input
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        autoComplete="off"
      />
      {value && (
        <button
          className="clear"
          onClick={() => onChange("")}
          aria-label="Limpiar"
        >
          ×
        </button>
      )}
    </div>
  );
}
