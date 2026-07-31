import React, { useState } from "react";
import frontendHtml from "@/../public/frontend.html?raw";
import appPy from "@/../public/app.py?raw";
import dbManager from "@/../public/db_manager.py?raw";

const FILES = [
  {
    nombre: "frontend/index.html",
    ruta: "/opt/pocsag-server/frontend/index.html",
    codigo: frontendHtml,
  },
  {
    nombre: "backend/app.py",
    ruta: "/opt/pocsag-server/backend/app.py",
    codigo: appPy,
  },
  {
    nombre: "database/db_manager.py",
    ruta: "/opt/pocsag-server/database/db_manager.py",
    codigo: dbManager,
  },
];

export default function Codigo() {
  const [activo, setActivo] = useState(0);
  const [copiado, setCopiado] = useState(false);

  const copiar = async () => {
    await navigator.clipboard.writeText(FILES[activo].codigo);
    setCopiado(true);
    setTimeout(() => setCopiado(false), 2000);
  };

  const f = FILES[activo];

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 p-6">
      <div className="max-w-5xl mx-auto">
        <h1 className="text-xl font-bold mb-4 flex items-center gap-2">
          🏥 <span>Archivos del servidor</span>
        </h1>

        <div className="flex gap-2 mb-4 flex-wrap">
          {FILES.map((file, i) => (
            <button
              key={file.nombre}
              onClick={() => setActivo(i)}
              className={`px-3 py-1.5 rounded-lg text-sm font-mono transition-colors ${
                i === activo
                  ? "bg-emerald-600 text-white"
                  : "bg-slate-800 text-slate-300 hover:bg-slate-700"
              }`}
            >
              {file.nombre}
            </button>
          ))}
        </div>

        <div className="flex items-center justify-between mb-2">
          <p className="text-slate-400 text-sm">
            Pegalo en <code className="text-emerald-400">{f.ruta}</code>
          </p>
          <button
            onClick={copiar}
            className="bg-emerald-600 hover:bg-emerald-500 text-white font-semibold px-4 py-2 rounded-lg transition-colors text-sm"
          >
            {copiado ? "✓ Copiado" : "Copiar código"}
          </button>
        </div>

        <pre className="bg-slate-900 border border-slate-800 rounded-lg p-4 overflow-auto text-xs leading-relaxed font-mono text-slate-300 max-h-[70vh]">
          <code>{f.codigo}</code>
        </pre>

        <p className="text-slate-500 text-xs mt-4">
          Después de pegar los tres, reiniciá el servicio:{" "}
          <code className="text-emerald-400">sudo systemctl restart pocsag-api</code>
        </p>
      </div>
    </div>
  );
}