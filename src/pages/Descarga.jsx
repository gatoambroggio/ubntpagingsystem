import React, { useState } from "react";
import {
  Download,
  Radio,
  AlertTriangle,
  CheckCircle2,
  Loader2,
  Terminal,
  ShieldAlert,
  RefreshCw,
  Server,
} from "lucide-react";
import JSZip from "jszip";

export default function Descarga() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ok, setOk] = useState(false);

  const descargarZip = async () => {
    setError("");
    setOk(false);
    setBusy(true);
    try {
      const res = await fetch("/instalador.sh");
      if (!res.ok)
        throw new Error("No se pudo obtener instalador.sh (HTTP " + res.status + ").");
      const instalador = await res.text();
      if (!instalador || instalador.length < 1000)
        throw new Error("El instalador vino vacio o incompleto.");
      const zip = new JSZip();
      zip.file("instalador.sh", instalador);
      const blob = await zip.generateAsync({ type: "blob" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "pocsag-instalador.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setOk(true);
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-slate-950 via-slate-950 to-slate-900 text-slate-100 flex items-center justify-center p-6">
      <div className="w-full max-w-2xl">
        {/* Hero */}
        <div className="flex items-center gap-3 mb-6">
          <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-emerald-500 to-cyan-500 grid place-items-center shadow-lg shadow-emerald-500/20">
            <Radio className="w-6 h-6 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-bold tracking-tight">Sistema POCSAG</h1>
            <p className="text-sm text-slate-400">Paginacion hospitalaria autonoma</p>
          </div>
        </div>

        {/* Main download card */}
        <div className="relative overflow-hidden rounded-3xl border border-slate-800 bg-slate-900/70 backdrop-blur p-8 shadow-2xl">
          <div className="absolute -top-24 -right-24 w-64 h-64 rounded-full bg-emerald-500/10 blur-3xl" />
          <div className="relative">
            <div className="flex items-start gap-4 mb-6">
              <div className="w-14 h-14 rounded-2xl bg-slate-800/80 border border-slate-700 grid place-items-center shrink-0">
                <Download className="w-7 h-7 text-emerald-400" />
              </div>
              <div>
                <h2 className="text-lg font-semibold">Descarga el instalador completo</h2>
                <p className="text-sm text-slate-400 leading-relaxed mt-1">
                  Un unico archivo <code className="text-emerald-400 font-mono">instalador.sh</code> con todo el
                  sistema embebido (panel web, backend, Asterisk, encoder POCSAG y base de datos).
                </p>
              </div>
            </div>

            <button
              onClick={descargarZip}
              disabled={busy}
              className="w-full bg-gradient-to-r from-emerald-500 to-cyan-500 hover:from-emerald-400 hover:to-cyan-400 disabled:opacity-60 disabled:cursor-not-allowed text-white font-semibold py-3.5 rounded-2xl transition-all flex items-center justify-center gap-2 shadow-lg shadow-emerald-500/25"
            >
              {busy ? (
                <>
                  <Loader2 className="w-5 h-5 animate-spin" />
                  Empaquetando...
                </>
              ) : (
                <>
                  <Download className="w-5 h-5" />
                  Descargar pocsag-instalador.zip
                </>
              )}
            </button>

            {ok && (
              <div className="mt-4 flex items-center gap-2 text-sm text-emerald-400 bg-emerald-500/10 border border-emerald-500/30 rounded-xl px-4 py-3">
                <CheckCircle2 className="w-4 h-4 shrink-0" />
                Descarga lista. Si no inicio sola, revisa que el navegador no bloqueo la descarga.
              </div>
            )}
            {error && (
              <div className="mt-4 flex items-start gap-2 text-sm text-rose-300 bg-rose-500/10 border border-rose-500/30 rounded-xl px-4 py-3">
                <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" />
                <span className="break-words">{error}</span>
              </div>
            )}

            <div className="mt-5 flex items-center gap-2 text-xs text-slate-500">
              <Server className="w-3.5 h-3.5" />
              <span>Despliegue en Ubuntu Server 22.04 LTS</span>
            </div>
          </div>
        </div>

        {/* Install instruction */}
        <div className="mt-5 rounded-2xl border border-slate-800 bg-slate-900/50 p-5">
          <div className="flex items-center gap-2 mb-3 text-slate-300">
            <Terminal className="w-4 h-4 text-cyan-400" />
            <span className="text-sm font-semibold">Instalacion</span>
          </div>
          <div className="bg-slate-950 border border-slate-800 rounded-xl px-4 py-3 font-mono text-sm">
            <span className="text-slate-500"># En el servidor Ubuntu 22.04</span>
            <div className="text-emerald-400 mt-1">sudo bash instalador.sh</div>
          </div>
        </div>

        {/* Recovery + update */}
        <div className="mt-5 grid gap-4 sm:grid-cols-2">
          <div className="rounded-2xl border border-slate-800 bg-slate-900/50 p-5">
            <div className="flex items-center gap-2 mb-2 text-slate-200">
              <ShieldAlert className="w-4 h-4 text-amber-400" />
              <span className="text-sm font-semibold">Si se rompio todo</span>
            </div>
            <p className="text-xs text-slate-400 leading-relaxed">
              Reinstala desde cero con{" "}
              <code className="text-emerald-400 font-mono">sudo bash instalador.sh --reset</code>.
              Hace backup automatico en <code className="text-slate-300">/tmp/</code> y reinstala sin fallar.
            </p>
          </div>
          <div className="rounded-2xl border border-slate-800 bg-slate-900/50 p-5">
            <div className="flex items-center gap-2 mb-2 text-slate-200">
              <RefreshCw className="w-4 h-4 text-cyan-400" />
              <span className="text-sm font-semibold">Actualizacion rapida</span>
            </div>
            <p className="text-xs text-slate-400 leading-relaxed">
              Edita <code className="text-emerald-400 font-mono">src/deploy.sh</code> con la IP de tu servidor y
              ejecuta <code className="text-emerald-400 font-mono">bash src/deploy.sh</code>. Sube solo los
              cambios y preserva la base. Ver <code className="text-slate-300">src/DEPLOY.md</code>.
            </p>
          </div>
        </div>

        <p className="text-center text-xs text-slate-600 mt-6">
          Desinstalar: <code className="font-mono text-slate-500">sudo /opt/pocsag-server/bin/uninstall.sh</code>
        </p>
      </div>
    </div>
  );
}