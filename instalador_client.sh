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
# DESPUES DE INSTALAR: desde el panel admin -> Parametros -> cargar la IP real
# del hospital y las claves de cada interno en Extensiones -> Aplicar a Asterisk.
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main"
AST_ETC="/etc/asterisk"
DB="/opt/pocsag-server/database/pocsag.db"
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
  echo "==> 1/5 Instalando sistema base POCSAG (servidor autonomo)..."
  TMP="$(mktemp -d)"
  if ! curl -fsSL "${REPO}/instalador.sh" -o "$TMP/instalador.sh"; then
    err "No se pudo descargar instalador.sh desde GitHub."; exit 1
  fi
  bash "$TMP/instalador.sh"
  rm -rf "$TMP"
else
  echo "==> 1/5 Modo --update: se saltea la instalacion base."
fi

# ============================ 2. PATCH APP + ADMIN ===========================
echo "==> 2/5 Parcheando app.py y admin.html (modo cliente)..."
TMP="$(mktemp -d)"
if ! curl -fsSL "${REPO}/src/pocsag-server-client/scripts/patch_client.py" -o "$TMP/patch_client.py"; then
  err "No se pudo descargar patch_client.py"; exit 1
fi
python3 "$TMP/patch_client.py"
# Hotfix: corregir parser de estado de registro SIP (bug que muestra todo en rojo)
curl -fsSL "${REPO}/src/pocsag-server-client/scripts/fix_status.py" -o "$TMP/fix_status.py" 2>/dev/null && python3 "$TMP/fix_status.py" 2>/dev/null || true
rm -rf "$TMP"

# ============================ 3. CONFIG CLIENTE ==============================
echo "==> 3/5 Descargando configuracion cliente (v${VERSION})..."
mkdir -p "$AST_ETC"
if ! curl -fsSL "${REPO}/src/pocsag-server-client/asterisk/pjsip_hospital.conf" -o "${AST_ETC}/pjsip_hospital.conf"; then
  err "No se pudo descargar pjsip_hospital.conf"; exit 1
fi
if ! curl -fsSL "${REPO}/src/pocsag-server-client/asterisk/extensions_hospital.conf" -o "${AST_ETC}/extensions_hospital.conf"; then
  err "No se pudo descargar extensions_hospital.conf"; exit 1
fi

# ============================ 4. MIGRACION BD ================================
echo "==> 4/5 Migrando base a modo cliente (internos 3000-3003)..."
python3 - <<PYEOF
import sqlite3
c = sqlite3.connect('${DB}')
# Quitar extensiones del servidor autonomo (101, 2184-2187)
c.execute("DELETE FROM extensiones WHERE numero IN ('101','2184','2185','2186','2187')")
# Insertar los 4 internos del hospital (si no existen)
for n in ('3000','3001','3002','3003'):
    c.execute("INSERT OR IGNORE INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
              (n, 'CAMBIAR_PASSWORD_' + n, 'pocsag-incoming', 'Interno hospital ' + n))
# Marcar modo cliente y version
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('pocsag_mode','client')")
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('hospital_pbx_ip','IP_HOSPITAL')")
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
c.commit(); c.close()
PYEOF

# Incluir pjsip_hospital.conf y extensions_hospital.conf
grep -q 'pjsip_hospital.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_hospital.conf' >> "${AST_ETC}/pjsip.conf"
grep -q 'extensions_hospital.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_hospital.conf' >> "${AST_ETC}/extensions.conf"

# ============================ 5. RELOAD =====================================
echo "==> 5/5 Recargando Asterisk..."
asterisk -rx "pjsip reload" 2>/dev/null || true
asterisk -rx "dialplan reload" 2>/dev/null || true
systemctl restart pocsag-api 2>/dev/null || true

echo "--------------------------------------------"
log "Sistema POCSAG cliente v${VERSION} instalado."
echo ""
echo "  Panel publico: http://localhost:8080/"
echo "  Panel admin  : http://localhost:8080/admin  (admin / admin123)"
echo ""
echo "  PROXIMO PASO (todo desde el panel admin):"
echo "    1) Parametros -> IP central del hospital -> cargar la IP real -> Guardar"
echo "    2) Extensiones -> editar cada interno (3000-3003) con su clave real"
echo "    3) Extensiones -> Aplicar a Asterisk  (regenera pjsip_hospital.conf)"
echo "    4) La columna 'Registro' muestra Registered / No registrado en vivo"
echo ""
echo "  Verificar por consola:"
echo "    sudo asterisk -rx 'pjsip show registrations'"