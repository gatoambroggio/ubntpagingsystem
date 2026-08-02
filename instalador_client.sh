#!/usr/bin/env bash
# ============================================================================
# instalador_client.sh - Sistema POCSAG variante CLIENTE (v1.0client)
# ============================================================================
# Registra internos (3000-3003 etc.) contra la central VoIP del hospital.
# Cuando el hospital marca uno de esos internos, el IVR POCSAG contesta.
#
# Arquitectura: instala la base con instalador.sh y luego REEMPLAZA (no parchea)
# app.py y admin.html con versiones cliente standalone que ya incluyen
# generar_pjsip_hospital_conf() y estado_registros_api() nativos.
#
# Uso (una linea desde GitHub):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
#
# Actualizar solo la config cliente (sin reinstalar la base):
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash -s -- --update
#
# DESPUES DE INSTALAR: desde el panel admin -> Parametros -> cargar la IP real
# del hospital -> Extensiones -> editar claves -> Aplicar a Asterisk.
# ============================================================================
set -euo pipefail

REPO="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main"
AST_ETC="/etc/asterisk"
APP_DIR="/opt/pocsag-server"
DB="${APP_DIR}/database/pocsag.db"
VERSION="1.0client"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}   $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC}  $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

dl(){ # dl <url> <dest>
  if ! curl -fsSL "$1" -o "$2"; then err "No se pudo descargar $1"; exit 1; fi
}

# ============================ 1. SISTEMA BASE ================================
if [[ $UPDATE -eq 0 ]]; then
  echo "==> 1/6 Instalando sistema base POCSAG (servidor autonomo)..."
  TMP="$(mktemp -d)"
  dl "${REPO}/instalador.sh" "$TMP/instalador.sh"
  bash "$TMP/instalador.sh"
  rm -rf "$TMP"
else
  echo "==> 1/6 Modo --update: se saltea la instalacion base."
fi

# ============================ 2. REEMPLAZAR APP.PY ===========================
echo "==> 2/6 Reemplazando app.py con version cliente (v${VERSION})..."
dl "${REPO}/src/pocsag-server-client/backend/app.py" "${APP_DIR}/backend/app.py"
chmod +x "${APP_DIR}/backend/app.py"

# ============================ 3. REEMPLAZAR ADMIN.HTML ======================
echo "==> 3/6 Reemplazando admin.html con version cliente..."
dl "${REPO}/src/pocsag-server-client/frontend/admin.html" "${APP_DIR}/frontend/admin.html"

# ============================ 4. CONFIG ASTERISK ============================
echo "==> 4/6 Configurando Asterisk cliente..."
mkdir -p "$AST_ETC"
# Dialplan autocontenido (IVR incluido) - siempre se actualiza (es estatico)
dl "${REPO}/src/pocsag-server-client/asterisk/extensions_hospital.conf" "${AST_ETC}/extensions_hospital.conf"
# pjsip_hospital.conf: solo descargar template en instalacion nueva.
# En --update NO pisar el archivo existente (tiene la IP y claves reales).
# Se regenera desde la DB en el paso 5 con generar_pjsip_hospital_conf().
if [[ $UPDATE -eq 0 ]] || [[ ! -f "${AST_ETC}/pjsip_hospital.conf" ]]; then
  dl "${REPO}/src/pocsag-server-client/asterisk/pjsip_hospital.conf" "${AST_ETC}/pjsip_hospital.conf"
fi

# Incluir desde extensions.conf y pjsip.conf si no estan ya
grep -q 'extensions_hospital.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_hospital.conf' >> "${AST_ETC}/extensions.conf"
grep -q 'pjsip_hospital.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_hospital.conf' >> "${AST_ETC}/pjsip.conf"

# ============================ 5. MIGRACION BD ================================
echo "==> 5/6 Migrando base a modo cliente (internos 3000-3003)..."
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
# IMPORTANTE: hospital_pbx_ip usa INSERT OR IGNORE para NO sobreescribir
# la IP real que el usuario ya configuro desde el panel admin.
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('pocsag_mode','client')")
c.execute("INSERT OR IGNORE INTO config(clave,valor) VALUES('hospital_pbx_ip','IP_HOSPITAL')")
c.execute("INSERT OR REPLACE INTO config(clave,valor) VALUES('version','${VERSION}')")
c.commit(); c.close()
PYEOF

# Regenerar pjsip_hospital.conf desde la DB (usa la IP y claves reales)
# Esto reconstruye el archivo con la config actual sin pisar los datos
python3 - <<'PYEOF2'
import sys, os
sys.path.insert(0, "/opt/pocsag-server/backend")
sys.path.insert(0, "/opt/pocsag-server")
os.chdir("/opt/pocsag-server")
try:
    from app import generar_pjsip_hospital_conf
    ok, msg = generar_pjsip_hospital_conf()
    if ok:
        print(f"[OK]   pjsip_hospital.conf regenerado: {msg}")
    else:
        print(f"[WARN] {msg}")
        print("       Configure la IP y claves desde el panel admin -> Aplicar a Asterisk")
except Exception as e:
    print(f"[WARN] No se pudo regenerar pjsip_hospital.conf: {e}")
PYEOF2

# ============================ 6. RELOAD =====================================
echo "==> 6/6 Recargando servicios..."
chown -R asterisk:asterisk "${APP_DIR}" "${AST_ETC}/pjsip_hospital.conf" "${AST_ETC}/extensions_hospital.conf" 2>/dev/null || true
asterisk -rx "pjsip reload" 2>/dev/null || true
asterisk -rx "dialplan reload" 2>/dev/null || true
systemctl restart pocsag-api 2>/dev/null || true
systemctl restart pocsag-cola 2>/dev/null || true

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
echo "    sudo asterisk -rx 'dialplan show pocsag-incoming'"