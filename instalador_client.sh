#!/usr/bin/env bash
# ============================================================================
# instalador_client.sh - Sistema POCSAG variante CLIENTE (v1.0client)
# ============================================================================
# Registra 4 internos (3000-3003) contra la central VoIP del hospital.
# Cuando el hospital marca 177 (enrutado a uno de los 4), dispara el IVR POCSAG.
#
# Uso (desde GitHub, una linea):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
#
# Actualizar solo la config cliente (sin reinstalar la base):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash -s -- --update
#
# DESPUES DE INSTALAR: editar /etc/asterisk/pjsip_hospital.conf y reemplazar
# IP_HOSPITAL y las passwords por los datos reales que de el IT del hospital.
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main"
AST_ETC="/etc/asterisk"
VERSION="1.0client"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

# ============================ 1. SISTEMA BASE ================================
if [[ $UPDATE -eq 0 ]]; then
  echo "==> 1/4 Instalando sistema base POCSAG (servidor autonomo)..."
  TMP="$(mktemp -d)"
  if ! curl -fsSL "${REPO}/instalador.sh" -o "$TMP/instalador.sh"; then
    err "No se pudo descargar instalador.sh desde GitHub."; exit 1
  fi
  bash "$TMP/instalador.sh"
  rm -rf "$TMP"
else
  echo "==> 1/4 Modo --update: se saltea la instalacion base."
fi

# ============================ 2. CONFIG CLIENTE ==============================
echo "==> 2/4 Descargando configuracion cliente (v${VERSION})..."
mkdir -p "$AST_ETC"
if ! curl -fsSL "${REPO}/src/pocsag-server-client/asterisk/pjsip_hospital.conf" -o "${AST_ETC}/pjsip_hospital.conf"; then
  err "No se pudo descargar pjsip_hospital.conf"; exit 1
fi
if ! curl -fsSL "${REPO}/src/pocsag-server-client/asterisk/extensions_hospital.conf" -o "${AST_ETC}/extensions_hospital.conf"; then
  err "No se pudo descargar extensions_hospital.conf"; exit 1
fi

# ============================ 3. INCLUDES ===================================
echo "==> 3/4 Integrando includes en pjsip.conf y extensions.conf..."
grep -q 'pjsip_hospital.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_hospital.conf' >> "${AST_ETC}/pjsip.conf"
grep -q 'extensions_hospital.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_hospital.conf' >> "${AST_ETC}/extensions.conf"

# Marcar version cliente en la base de datos
python3 -c "
import sqlite3
c = sqlite3.connect('/opt/pocsag-server/database/pocsag.db')
c.execute('INSERT OR REPLACE INTO config(clave,valor) VALUES(?,?)', ('version','${VERSION}'))
c.commit(); c.close()
" 2>/dev/null || warn "No se pudo actualizar version en la base."

# ============================ 4. RELOAD =====================================
echo "==> 4/4 Recargando Asterisk..."
asterisk -rx "pjsip reload" 2>/dev/null || true
asterisk -rx "dialplan reload" 2>/dev/null || true

echo "--------------------------------------------"
log "Sistema POCSAG cliente v${VERSION} instalado."
echo ""
echo "  Panel publico: http://localhost:8080/"
echo "  Panel admin  : http://localhost:8080/admin  (admin / admin123)"
echo ""
echo "  PROXIMO PASO - Editar credenciales del hospital:"
echo "    sudo nano ${AST_ETC}/pjsip_hospital.conf"
echo "    (reemplazar IP_HOSPITAL y CAMBIAR_PASSWORD_3000..3003)"
echo "    sudo asterisk -rx 'pjsip reload'"
echo ""
echo "  Verificar registros:"
echo "    sudo asterisk -rx 'pjsip show registrations'"
echo "    (los 4 internos deben decir 'Registered')"
echo ""
echo "  Probar: llamar desde un interno del hospital al 177."
echo "    Debe escuchar el IVR: 'Despues del tono marque el codigo'"