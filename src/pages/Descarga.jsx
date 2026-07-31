import React from "react";
import instaladorContent from "@/../instalador.sh?raw";

export default function Descarga() {
  const descargar = () => {
    const blob = new Blob([instaladorContent], { type: "application/x-sh" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "instalador.sh";
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex items-center justify-center p-6">
      <div className="max-w-2xl w-full bg-slate-900 border border-slate-800 rounded-2xl shadow-xl p-8">
        <div className="flex items-center gap-3 mb-4">
          <span className="text-3xl">🏥</span>
          <h1 className="text-2xl font-bold">Sistema POCSAG — Descarga</h1>
        </div>
        <p className="text-slate-300 mb-6 leading-relaxed">
          Este archivo único contiene <strong>todo el sistema</strong> embebido
          (Asterisk, AGI, codificador POCSAG, base de datos, API, panel web,
          servicios y locuciones). Lo pasás al servidor Ubuntu y se instala con
          un solo comando.
        </p>

        <div className="bg-slate-950 border border-slate-800 rounded-lg p-4 mb-6 font-mono text-sm">
          <div className="text-slate-500"># 1) Descargar el archivo de arriba</div>
          <div className="text-slate-300"># 2) Subirlo al servidor Ubuntu 22.04</div>
          <div className="text-emerald-400">sudo bash instalador.sh</div>
        </div>

        <button
          onClick={descargar}
          className="w-full bg-emerald-600 hover:bg-emerald-500 text-white font-semibold py-3 rounded-lg transition-colors flex items-center justify-center gap-2"
        >
          ⬇ Descargar instalador.sh
        </button>

        <p className="text-xs text-slate-500 mt-4 text-center">
          Desinstalar luego: sudo /opt/pocsag-server/bin/uninstall.sh
        </p>
      </div>
    </div>
  );
}