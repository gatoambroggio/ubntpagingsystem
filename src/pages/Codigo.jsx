import React, { useState, useEffect } from "react";
import { FileCode, Copy, Check, Server, Terminal } from "lucide-react";

const FILES = [
  { nombre: "frontend/index.html", ruta: "/opt/pocsag-server/frontend/index.html", url: "/frontend.html" },
  { nombre: "backend/app.py", ruta: "/opt/pocsag-server/backend/app.py", url: "/app.py" },
  { nombre: "database/db_manager.py", ruta: "/opt/pocsag-server/database/db_manager.py", url: "/db_manager.py" },
];

export default function Codigo() {
  const [activo, setActivo] = useState(0);
  const [copiado, setCopiado] = useState(false);
  const [contenidos, setContenidos] = useState({});
  const [errores, setErrores] = useState({});

  useEffect(() => {
    if (contenidos[activo] !== undefined || errores[activo]) return;
    let cancelled = false;
    fetch(FILES[activo].url)
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.text();
      })
      .then((t) => {
        if (!cancelled) setContenidos((c) => ({ ...c, [activo]: t }));
      })
      .catch((e) => {
        if (!cancelled) setErrores((er) => ({ ...er, [activo]: e.message }));
      });
    return () => {
      cancelled = true;
    };
  }, [activo, contenidos, errores]);

  const copiar = async () => {
    await navigator.clipboard.writeText(contenidos[activo] || "");
    setCopiado(true);
    setTimeout(() => setCopiado(false), 2000);
  };

  const f = FILES[activo];
  const codigo = contenidos[activo];
  const err = errores[activo];

  return (
    <div className="min-h-screen bg-gradient-to-b from-slate-950 to-slate-900 text-slate-100 p-6">
      <div className="max-w-5xl mx-auto">
        <div className="flex items-center gap-3 mb-6">
          <div className="w-11 h-11 rounded-2xl bg-gradient-to-br from-emerald-500 to-cyan-500 grid place-items-center shadow-lg shadow-emerald-500/20">
            <FileCode className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold tracking-tight">Archivos del servidor</h1>
            <p className="text-sm text-slate-400">Codigo fuente para pegar en el servidor Ubuntu</p>
          </div>
        </div>

        <div className="flex gap-2 mb-4 flex-wrap">
          {FILES.map((file, i) => (
            <button
              key={file.nombre}
              onClick={() => setActivo(i)}
              className={`px-3.5 py-2 rounded-xl text-sm font-mono transition-all ${
                i === activo
                  ? "bg-gradient-to-r from-emerald-500 to-cyan-500 text-white shadow-md shadow-emerald-500/25"
                  : "bg-slate-800/70 text-slate-300 hover:bg-slate-700/70 border border-slate-700/50"
              }`}
            >
              {file.nombre}
            </button>
          ))}
        </div>

        <div className="flex items-center justify-between mb-3 flex-wrap gap-2">
          <p className="text-slate-400 text-sm flex items-center gap-2">
            <Server className="w-4 h-4 text-cyan-400" />
            Pegalo en <code className="text-emerald-400 font-mono">{f.ruta}</code>
          </p>
          <button
            onClick={copiar}
            disabled={!codigo}
            className="inline-flex items-center gap-2 bg-gradient-to-r from-emerald-500 to-cyan-500 hover:from-emerald-400 hover:to-cyan-400 disabled:opacity-50 text-white font-semibold px-4 py-2 rounded-xl transition-all text-sm shadow-md shadow-emerald-500/20"
          >
            {copiado ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
            {copiado ? "Copiado" : "Copiar codigo"}
          </button>
        </div>

        <div className="rounded-2xl border border-slate-800 bg-slate-950 overflow-hidden">
          {err ? (
            <div className="p-6 text-sm text-rose-300">
              No se pudo cargar el archivo ({err}). Verifica que exista en el servidor.
            </div>
          ) : codigo === undefined ? (
            <div className="p-6 text-sm text-slate-500 flex items-center gap-2">
              <span className="w-4 h-4 border-2 border-slate-700 border-t-emerald-500 rounded-full animate-spin" />
              Cargando...
            </div>
          ) : (
            <pre className="p-4 overflow-auto text-xs leading-relaxed font-mono text-slate-300 max-h-[68vh]">
              <code>{codigo}</code>
            </pre>
          )}
        </div>

        <div className="mt-4 flex items-center gap-2 text-xs text-slate-500">
          <Terminal className="w-3.5 h-3.5 text-cyan-400" />
          Despues de pegar los tres, reinicia el servicio:{" "}
          <code className="text-emerald-400 font-mono">sudo systemctl restart pocsag-api</code>
        </div>
      </div>
    </div>
  );
}