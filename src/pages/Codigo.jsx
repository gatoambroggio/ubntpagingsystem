import React, { useState } from "react";
import frontendHtml from "@/../public/frontend.html?raw";

export default function Codigo() {
  const [copiado, setCopiado] = useState(false);

  const copiar = async () => {
    await navigator.clipboard.writeText(frontendHtml);
    setCopiado(true);
    setTimeout(() => setCopiado(false), 2000);
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 p-6">
      <div className="max-w-5xl mx-auto">
        <div className="flex items-center justify-between mb-4">
          <h1 className="text-xl font-bold flex items-center gap-2">
            🏥 <span>frontend/index.html</span>
          </h1>
          <button
            onClick={copiar}
            className="bg-emerald-600 hover:bg-emerald-500 text-white font-semibold px-4 py-2 rounded-lg transition-colors text-sm"
          >
            {copiado ? "✓ Copiado" : "Copiar código"}
          </button>
        </div>
        <p className="text-slate-400 text-sm mb-4">
          Pegalo en <code className="text-emerald-400">/opt/pocsag-server/frontend/index.html</code> del servidor.
        </p>
        <pre className="bg-slate-900 border border-slate-800 rounded-lg p-4 overflow-auto text-xs leading-relaxed font-mono text-slate-300">
          <code>{frontendHtml}</code>
        </pre>
      </div>
    </div>
  );
}