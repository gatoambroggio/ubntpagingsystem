import React, { useState } from "react";
import { motion } from "framer-motion";
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
const RAW =
  "https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador.sh";

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

const fade = {
  hidden: { opacity: 0, y: 18 },
  show: (i) => ({
    opacity: 1,
    y: 0,
    transition: { delay: 0.08 * i, duration: 0.5, ease: [0.22, 1, 0.36, 1] },
  }),
};

export default function Descarga() {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [ok, setOk] = useState("");
  const [copied, setCopied] = useState("");

  const copiar = (txt, id) => {
    navigator.clipboard.writeText(txt);
    setCopied(id);
    setTimeout(() => setCopied(""), 2000);
  };

  const descargarZip = async () => {
    setError("");
    setOk("");
    setBusy(true);
    try {
      const zip = new JSZip();
      const r1 = await fetch("/instalador.sh");
      if (!r1.ok)
        throw new Error("No se pudo obtener instalador.sh (HTTP " + r1.status + ").");
      const instalador = await r1.text();
      if (instalador.length < 1000 || instalador.trimStart().startsWith("<"))
        throw new Error("instalador.sh vino vacio o como HTML.");
      zip.file("instalador.sh", instalador);
      try {
        const r2 = await fetch("/source-manifest.json");
        const txt = await r2.text();
        if (txt && !txt.trimStart().startsWith("<")) {
          const manifest = JSON.parse(txt);
          for (const rel of manifest) {
            const rf = await fetch("/source/" + rel);
            if (!rf.ok) continue;
            const body = await rf.text();
            if (body && !body.trimStart().startsWith("<")) zip.file(rel, body);
          }
        }
      } catch {}
      const blob = await zip.generateAsync({ type: "blob" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "pocsag-completo.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      setOk("Descarga lista: pocsag-completo.zip con instalador.sh + carpeta source/pocsag-server/.");
    } catch (e) {
      setError(e.message || String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="relative min-h-screen overflow-hidden bg-[#070b16] text-slate-100">
      {/* animated mesh */}
      <div className="pointer-events-none fixed inset-0 overflow-hidden">
        <motion.div
          className="absolute -top-40 -left-32 w-[34rem] h-[34rem] rounded-full bg-cyan-500/20 blur-[120px]"
          animate={{ x: [0, 40, 0], y: [0, 30, 0], scale: [1, 1.1, 1] }}
          transition={{ duration: 16, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute top-1/3 -right-40 w-[30rem] h-[30rem] rounded-full bg-indigo-500/20 blur-[120px]"
          animate={{ x: [0, -50, 0], y: [0, 40, 0], scale: [1, 1.15, 1] }}
          transition={{ duration: 18, repeat: Infinity, ease: "easeInOut" }}
        />
        <motion.div
          className="absolute bottom-0 left-1/3 w-[28rem] h-[28rem] rounded-full bg-emerald-500/15 blur-[120px]"
          animate={{ x: [0, 30, 0], y: [0, -30, 0], scale: [1, 1.1, 1] }}
          transition={{ duration: 20, repeat: Infinity, ease: "easeInOut" }}
        />
      </div>

      <div className="relative max-w-2xl mx-auto px-6 py-10">
        {/* Hero */}
        <motion.div custom={0} variants={fade} initial="hidden" animate="show" className="flex items-center gap-3 mb-8">
          <div className="w-14 h-14 rounded-3xl bg-gradient-to-br from-emerald-400 via-cyan-400 to-indigo-500 grid place-items-center shadow-xl shadow-cyan-500/30">
            <Radio className="w-7 h-7 text-white" />
          </div>
          <div>
            <h1 className="text-2xl font-bold tracking-tight bg-gradient-to-r from-white via-cyan-100 to-indigo-200 bg-clip-text text-transparent">
              Sistema POCSAG
            </h1>
            <p className="text-sm text-slate-400">Paginacion hospitalaria autonoma &middot; 2026</p>
          </div>
        </motion.div>

        {/* GitHub install */}
        <motion.div
          custom={1}
          variants={fade}
          initial="hidden"
          animate="show"
          className="relative rounded-[28px] p-[1px] bg-gradient-to-br from-cyan-500/40 via-transparent to-indigo-500/40 mb-5"
        >
          <div className="rounded-[27px] bg-[#0b1322]/80 backdrop-blur-xl p-6">
            <div className="flex items-center gap-2 mb-1">
              <Github className="w-5 h-5 text-cyan-400" />
              <h2 className="text-base font-semibold">Instalar desde GitHub (recomendado)</h2>
            </div>
            <p className="text-xs text-slate-400 mb-4 leading-relaxed">
              Baja siempre la ultima version del instalador y el codigo fuente directo del repositorio. Una sola linea en el servidor Ubuntu 22.04.
            </p>
            <div className="bg-black/40 border border-white/5 rounded-2xl px-4 py-3 font-mono text-xs mb-3">
              <div className="text-slate-500"># Opcion A - una linea (instalador autocontenido)</div>
              <button
                onClick={() => copiar(`curl -fsSL ${RAW} | sudo bash`, "a")}
                className="block text-left text-emerald-400 mt-1 w-full hover:text-emerald-300"
              >
                curl -fsSL {RAW} | sudo bash
                {copied === "a" && <Check className="w-3 h-3 inline ml-2 text-cyan-400" />}
              </button>
            </div>
            <div className="bg-black/40 border border-white/5 rounded-2xl px-4 py-3 font-mono text-xs">
              <div className="text-slate-500"># Opcion B - clonar repositorio completo (con source)</div>
              <button
                onClick={() =>
                  copiar(`git clone ${REPO} /tmp/pocsag && cd /tmp/pocsag && sudo bash instalador.sh`, "b")
                }
                className="block text-left text-emerald-400 mt-1 w-full hover:text-emerald-300 break-all"
              >
                git clone {REPO} /tmp/pocsag {"&&"} cd /tmp/pocsag {"&&"} sudo bash instalador.sh
                {copied === "b" && <Check className="w-3 h-3 inline ml-2 text-cyan-400" />}
              </button>
            </div>
            <button
              onClick={() => copiar(BOOTSTRAP, "boot")}
              className="mt-3 inline-flex items-center gap-2 text-xs text-slate-300 hover:text-cyan-400"
            >
              {copied === "boot" ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
              {copied === "boot" ? "Bootstrap copiado" : "Copiar script instalar-desde-github.sh"}
            </button>
          </div>
        </motion.div>

        {/* Offline zip */}
        <motion.div
          custom={2}
          variants={fade}
          initial="hidden"
          animate="show"
          className="rounded-[28px] bg-white/[0.03] border border-white/10 backdrop-blur-xl p-6 mb-5"
        >
          <div className="flex items-start gap-3 mb-4">
            <div className="w-11 h-11 rounded-2xl bg-gradient-to-br from-emerald-500/30 to-cyan-500/30 border border-white/10 grid place-items-center shrink-0">
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
          <motion.button
            whileHover={{ scale: busy ? 1 : 1.01 }}
            whileTap={{ scale: 0.99 }}
            onClick={descargarZip}
            disabled={busy}
            className="w-full bg-gradient-to-r from-emerald-500 via-cyan-500 to-indigo-500 hover:brightness-110 disabled:opacity-60 text-white font-semibold py-3.5 rounded-2xl transition-all flex items-center justify-center gap-2 shadow-lg shadow-cyan-500/30"
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
          </motion.button>
          {ok && (
            <div className="mt-4 flex items-start gap-2 text-sm text-emerald-300 bg-emerald-500/10 border border-emerald-500/30 rounded-2xl px-4 py-3">
              <CheckCircle2 className="w-4 h-4 shrink-0 mt-0.5" />
              <span>{ok}</span>
            </div>
          )}
          {error && (
            <div className="mt-4 flex items-start gap-2 text-sm text-rose-300 bg-rose-500/10 border border-rose-500/30 rounded-2xl px-4 py-3">
              <AlertTriangle className="w-4 h-4 shrink-0 mt-0.5" />
              <span className="break-words">{error}</span>
            </div>
          )}
        </motion.div>

        {/* Update help */}
        <motion.div
          custom={3}
          variants={fade}
          initial="hidden"
          animate="show"
          className="rounded-2xl bg-white/[0.03] border border-white/10 backdrop-blur-xl p-5 mb-5"
        >
          <div className="flex items-center gap-2 mb-3 text-slate-200">
            <Terminal className="w-4 h-4 text-amber-400" />
            <span className="text-sm font-semibold">¿No te actualizo el sistema?</span>
          </div>
          <p className="text-xs text-slate-400 leading-relaxed mb-3">
            El instalador reescribe los archivos desde su contenido embebido. Para forzar la actualizacion de
            UI/backend sin tocar la base de datos:
          </p>
          <div className="bg-black/40 border border-white/5 rounded-xl px-4 py-2.5 font-mono text-xs text-emerald-400">
            sudo bash instalador.sh --update {"&&"} sudo systemctl restart pocsag-api
          </div>
          <p className="text-xs text-slate-500 mt-2">
            Despues abri el panel en incognito (Ctrl+Shift+N) para saltear la cache del navegador.
          </p>
        </motion.div>

        <motion.div
          custom={4}
          variants={fade}
          initial="hidden"
          animate="show"
          className="flex items-center gap-2 text-xs text-slate-500 justify-center"
        >
          <Server className="w-3.5 h-3.5" />
          Despliegue en Ubuntu Server 22.04 LTS
        </motion.div>
      </div>
    </div>
  );
}