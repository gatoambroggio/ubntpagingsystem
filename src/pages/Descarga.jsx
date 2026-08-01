import React, { useState } from "react";
import JSZip from "jszip";
import instaladorContent from "@/../instalador.sh?raw";

// Carga el contenido de los archivos web de src/ en build-time.
// Los .py/.sh/.html/.sql del pocsag-server ya van embebidos dentro de instalador.sh.
const srcFiles = import.meta.glob("/src/**/*.{js,jsx,ts,tsx,json,css,md}", {
  query: "?raw",
  import: "default",
  eager: true,
});

export default function Descarga() {
  const [busy, setBusy] = useState(false);
  const [count, setCount] = useState(0);

  const descargarZip = async () => {
    setBusy(true);
    try {
      const zip = new JSZip();
      let n = 0;
      // Archivos individuales de src/
      for (const [path, content] of Object.entries(srcFiles)) {
        const rel = path.replace(/^\/src\//, "src/");
        zip.file(rel, content);
        n++;
      }
      // Instalador único en la raíz del zip
      zip.file("instalador.sh", instaladorContent);
      setCount(n);

      const blob = await zip.generateAsync({ type: "blob" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "pocsag-server-src.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex items-center justify-center p-6">
      <div className="max-w-2xl w-full bg-slate-900 border border-slate-800 rounded-2xl shadow-xl p-8">
        <div className="flex items-center gap-3 mb-4">
          <span className="text-3xl">🏥</span>
          <h1 className="text-2xl font-bold">Sistema POCSAG — Descarga</h1>
        </div>
        <p className="text-slate-300 mb-6 leading-relaxed">
          Descargá <strong>toda la carpeta <code className="text-emerald-400">src/</code></strong> del
          proyecto en un único <code className="text-emerald-400">.zip</code>, más el
          instalador único <code className="text-emerald-400">instalador.sh</code> que
          contiene el sistema completo embebido.
        </p>

        <div className="bg-slate-950 border border-slate-800 rounded-lg p-4 mb-6 font-mono text-sm">
          <div className="text-slate-500"># En el servidor Ubuntu 22.04</div>
          <div className="text-emerald-400">sudo bash instalador.sh</div>
        </div>

        <button
          onClick={descargarZip}
          disabled={busy}
          className="w-full bg-emerald-600 hover:bg-emerald-500 disabled:opacity-50 disabled:cursor-not-allowed text-white font-semibold py-3 rounded-lg transition-colors flex items-center justify-center gap-2"
        >
          {busy ? "Empaquetando…" : "⬇ Descargar pocsag-server-src.zip"}
        </button>

        {count > 0 && (
          <p className="text-xs text-slate-500 mt-4 text-center">
            {count} archivos de src/ + instalador.sh incluidos
          </p>
        )}
        <p className="text-xs text-slate-500 mt-2 text-center">
          Desinstalar luego: sudo /opt/pocsag-server/bin/uninstall.sh
        </p>
        <div className="mt-6 border-t border-slate-800 pt-4">
          <p className="text-sm text-slate-300 leading-relaxed">
            <strong className="text-slate-100">Actualizacion rapida (sin reinstalar todo):</strong>{" "}
            edita <code className="text-emerald-400">src/deploy.sh</code> con la
            direccion de tu servidor y ejecuta{" "}
            <code className="text-emerald-400">bash src/deploy.sh</code>. Sube
            solo los cambios y preserva la base de datos. Ver{" "}
            <code className="text-emerald-400">src/DEPLOY.md</code> para la guia
            completa (incluye como funciona rsync).
          </p>
        </div>
      </div>
    </div>
  );
}