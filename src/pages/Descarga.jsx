import React, { useState } from "react";
import {
  Download,
  Radio,
  AlertTriangle,
  CheckCircle2,
  Loader2,
  Github,
  Copy,
  Check,
  FolderTree,
  Terminal,
  Server,
} from "lucide-react";
import JSZip from "jszip";

const REPO = "https://github.com/gatoambroggio/ubntpagingsystem.git";
const RAW = "https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador.sh";

const BOOTSTRAP = `#!/usr/bin/env bash
# Instala el sistema POCSAG clonando el repositorio desde GitHub.
set -euo pipefail
TMP="$(mktemp -d)"
echo "==> Clonando repositorio desde GitHub..."
git clone --depth 1 ${REPO} "$TMP"
cd "$TMP"
echo "==> Ejecutando instalador (podes pasar --update o --reset)..."
sudo bash instalador.sh "$@"
echo ""
echo "[OK] Sistema POCSAG instalado."
echo "     Panel publico: http://localhost:8080/"
echo "     Panel admin  : http://localhost:8080/admin"
`;

export default function Descarga() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ok, setOk] = useState("");
  const [copied, setCopied] = useState("");
  const [copiedRaw, setCopiedRaw] = useState(false);

  const copiar = (txt, id, setter) => {
    navigator.clipboard.writeText(txt);
    setter(true);
    setTimeout(() => setter(false), 2000);
  };

  const descargarZip = async () => {
    setError("");
    setOk("");
    setBusy(true);
    try {
      const zip = new JSZip();
      // instalador.sh
      const r1 = await fetch("/instalador.sh");
      if (!r1.ok) throw new Error("No se pudo obtener instalador.sh (HTTP " + r1.status + ").");
      const instalador = await r1.text();
      if (instalador.length < 1000) throw new Error("instalador.sh vino vacio o incompleto.");
      zip.file("instalador.sh", instalador);
      // bootstrap github
      zip.file("instalar-desde-github.sh", BOOTSTRAP);
      // source folder
      const r2 = await fetch("/source-manifest.json");
      if (r2.ok) {
        const manifest = await r2.json();
        for (const rel of manifest) {
          const rf = await fetch("/source/" + rel);
          if (!rf.ok) continue;
          const txt = await rf.text();
          zip.file(rel, txt);
        }
      }
      // readme
      zip.file(
        "LEEME.txt",
        "Sistema de Paginacion Hospitalaria POCSAG sobre VoIP\n" +
          "===================================================\n\n" +
          "OPCION 1 - Instalacion automatica desde GitHub (recomendado):\n" +
          "  bash instalar-desde-github.sh\n\n" +
          "  o en una linea:\n" +
          "  curl -fsSL " + RAW + " | sudo bash\n\n" +
          "OPCION 2 - Instalacion offline con este paquete:\n" +
          "  sudo bash instalador.sh\n\n" +
          "Actualizar (preserva base de datos y configs):\n" +
          "  sudo bash instalador.sh --update\n\n" +
          "Reinstalar desde cero (backup automatico en /tmp):\n" +
          "  sudo bash instalador.sh --reset\n\n" +
          "Desinstalar:\n" +
          "  sudo /opt/pocsag-server/bin/uninstall.sh\n\n" +
          "La carpeta pocsag-server/ contiene el codigo fuente editable\n" +
          "(backend, frontend, encoder, AGI, base de datos, etc.).\n" +
          "instalador.sh ya tiene todo embebido; el source es para editar/revisar.\n\n" +
          "Paneles:\n" +
          "  Publico: http://localhost:8080/\n" +
          "  Admin:   http://localhost:8080/admin\n"
      );
      const blob = await zip.generateAsync({ type: "blob" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "pocsag-completo.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setOk("Descarga lista: pocsag-completo.zip con instalador + carpeta source + bootstrap de GitHub.");
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-slate-950 via-slate-950 to-slate-900 text-slate-100">
      <div className="max-w-2xl mx-auto p-6">
        {/* Hero */}
        <div className="flex items-center gap-3 mb-6 pt-4">
          <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-emerald-500 to-cyan-500 grid place-items-center shadow-lg shadow-emerald-500/20">
            <Radio className="w-6 h-6 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-bold tracking-tight">Sistema POCSAG</h1>
            <p className="text-sm text-slate-400">Paginacion hospitalaria autonoma</p>
          </div>
        </div>

        {/* GitHub install (primary) */}
        <div className="relative overflow-hidden rounded-3xl border border-slate-800 bg-slate-900/70 backdrop-blur p-6 shadow-2xl mb-5">
          <div className="absolute -top-20 -right-20 w-56 h-56 rounded-full bg-cyan-500/10 blur-3xl" />
          <div className="relative">
            <div className="flex items-center gap-2 mb-1">
              <Github className="w-5 h-5 text-cyan-400" />
              <h2 className="text-base font-semibold">Instalar desde GitHub (recomendado)</h2>
            </div>
            <p className="text-xs text-slate-400 mb-4 leading-relaxed">
              Baja siempre la ultima version del instalador y el codigo fuente directo del repositorio. Una sola linea en el servidor Ubuntu 22.04.
            </p>
            <div className="bg-slate-950 border border-slate-800 rounded-xl px-4 py-3 font-mono text-xs mb-3">
              <div className="text-slate-500"># Opcion A - una linea (instalador autocontenido)</div>
              <button
                onClick={() => copiar(`curl -fsSL ${RAW} | sudo bash`, "a", setCopied)}
                className="block text-left text-emerald-400 mt-1 w-full hover:text-emerald-300"
              >
                curl -fsSL {RAW} | sudo bash
                {copied === "a" && <Check className="w-3 h-3 inline ml-2 text-cyan-400" />}
              </button>
            </div>
            <div className="bg-slate-950 border border-slate-800 rounded-xl px-4 py-3 font-mono text-xs">
              <div className="text-slate-500"># Opcion B - clonar repositorio completo (con source)</div>
              <button
                onClick={() =>
                  copiar(
                    `git clone ${REPO} /tmp/pocsag && cd /tmp/pocsag && sudo bash instalador.sh`,
                    "b",
                    setCopied
                  )
                }
                className="block text-left text-emerald-400 mt-1 w-full hover:text-emerald-300 break-all"
              >
                git clone {REPO} /tmp/pocsag {"&&"} cd /tmp/pocsag {"&&"} sudo bash instalador.sh
                {copied === "b" && <Check className="w-3 h-3 inline ml-2 text-cyan-400" />}
              </button>
            </div>
            <button
              onClick={() => copiar(BOOTSTRAP, "boot", setCopied)}
              className="mt-3 inline-flex items-center gap-2 text-xs text-slate-300 hover:text-cyan-400"
            >
              {copied === "boot" ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
              {copied === "boot" ? "Bootstrap copiado" : "Copiar script instalar-desde-github.sh"}
            </button>
          </div>
        </div>

        {/* Offline zip */}
        <div className="rounded-3xl border border-slate-800 bg-slate-900/50 p-6 mb-5">
          <div className="flex items-start gap-3 mb-4">
            <div className="w-11 h-11 rounded-2xl bg-slate-800/80 border border-slate-700 grid place-items-center shrink-0">
              <FolderTree className="w-5 h-5 text-emerald-400" />
            </div>
            <div>
              <h2 className="text-base font-semibold">Descargar ZIP completo (offline)</h2>
              <p className="text-xs text-slate-400 leading-relaxed mt-1">
                Incluye <code className="text-emerald-400 font-mono">instalador.sh</code>, la carpeta{" "}
                <code className="text-emerald-400 font-mono">pocsag-server/</code> (source editable) y el
                bootstrap de GitHub.
              </p>
            </div>
          </div>
          <button
            onClick={descargarZip}
            disabled={busy}
            className="w-full bg-gradient-to-r from-emerald-500 to-cyan-500 hover:from-emerald-400 hover:to-cyan-400 disabled:opacity-60 text-white font-semibold py-3 rounded-2xl transition-all flex items-center justify-center gap-2 shadow-lg shadow-emerald-500/25"
          >
            {busy ? (
              <>
                <Loader2 className="w-5 h-5 animate-spin" /> Empaquetando...
              </>
            ) : (
              <>
                <Download className="w-5 h-5" /> Descargar pocsag-completo.zip
              </>
            )}
          </button>
          {ok && (
            <div className="mt-3 flex items-start gap-2 text-sm text-emerald-400 bg-emerald-500/10 border border-emerald-500/30 rounded-xl px-4 py-3">
              <CheckCircle2 className="w-4 h-4 shrink-0 mt-0.5" />
              <span>{ok}</span>
            </div>
          )}
          {error && (
            <div className="mt-3 flex items-start gap-2 text-sm text-rose-300 bg-rose-500/10 border border-rose-500/30 rounded-xl px-4 py-3">
              <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" />
              <span className="break-words">{error}</span>
            </div>
          )}
        </div>

        {/* Update help */}
        <div className="rounded-2xl border border-slate-800 bg-slate-900/50 p-5 mb-5">
          <div className="flex items-center gap-2 mb-3 text-slate-200">
            <Terminal className="w-4 h-4 text-amber-400" />
            <span className="text-sm font-semibold">¿No te actualizo el sistema?</span>
          </div>
          <p className="text-xs text-slate-400 leading-relaxed mb-3">
            El instalador reescribe los archivos desde su contenido embebido. Para forzar la actualizacion de
            UI/backend sin tocar la base de datos:
          </p>
          <div className="bg-slate-950 border border-slate-800 rounded-xl px-4 py-2.5 font-mono text-xs text-emerald-400">
            sudo bash instalador.sh --update {"&&"} sudo systemctl restart pocsag-api
          </div>
          <p className="text-xs text-slate-500 mt-2">
            Despues, abri el panel en una pestaña de incognito (Ctrl+Shift+N) para saltear la cache del navegador.
          </p>
        </div>

        <div className="flex items-center gap-2 text-xs text-slate-500 justify-center">
          <Server className="w-3.5 h-3.5" />
          Despliegue en Ubuntu Server 22.04 LTS
        </div>
      </div>
    </div>
  );
}