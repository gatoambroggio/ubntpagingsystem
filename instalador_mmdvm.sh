#!/usr/bin/env bash
# ============================================================================
# instalador_mmdvm.sh  -  Backend MMDVM serial para ZetronPOC / MediGuard OS
# ============================================================================
# Conecta un modulo MMDVM UHF/VHF a una PC con Ubuntu Server 22.04 por puerto
# serie (USB-TTL), sin Raspberry y sin audio .wav. MMDVMHost genera la FSK de
# POCSAG con desviacion y timing exactos; el sistema le inyecta los mensajes
# por Remote Control (sin DAPNET, 100% local).
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_mmdvm.sh | sudo bash
#   sudo bash instalador_mmdvm.sh
#
# Variables (env):
#   MMDVM_PORT=/dev/ttyUSB0   Puerto serie del adaptador USB-TTL
#   MMDVM_BAUD=115200         Baudios del enlace host<->modem
#   MMDVM_CALLSIGN=LU1ABC     Identificacion
#   MMDVM_FREQ=433800000      Frecuencia TX/RX en Hz (433.800 MHz)
#   MMDVM_RCPORT=7642         Puerto del Remote Control de MMDVMHost
#   MMDVM_TXLEVEL=50          Nivel TX POCSAG (0-100)
#   MMDVM_TXINVERT=1          Invertir TX (1=si 0=no)
#   MMDVM_DUPLEX=0            0=simplex 1=duplex
# ============================================================================
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "[ERR] Ejecuta como root o con sudo." >&2; exit 1; }

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log()  { echo -e "${G}[OK]${NC}   $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR]${NC}  $*" >&2; }

APP_DIR="/opt/pocsag-server"
MMDVM_DIR="$APP_DIR/mmdvm"
MMDVM_HOST_DIR="/opt/MMDVMHost"
REPO_BASE="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador.sh"

MMDVM_PORT="${MMDVM_PORT:-/dev/ttyUSB0}"
MMDVM_BAUD="${MMDVM_BAUD:-115200}"
MMDVM_CALLSIGN="${MMDVM_CALLSIGN:-LU1ABC}"
MMDVM_FREQ="${MMDVM_FREQ:-433800000}"
MMDVM_RCPORT="${MMDVM_RCPORT:-7642}"
MMDVM_TXLEVEL="${MMDVM_TXLEVEL:-50}"
MMDVM_TXINVERT="${MMDVM_TXINVERT:-1}"
MMDVM_DUPLEX="${MMDVM_DUPLEX:-0}"

export DEBIAN_FRONTEND=noninteractive
export TZ="America/Argentina/Cordoba"

echo "==> instalador_mmdvm.sh - Backend MMDVM serial para ZetronPOC"
echo "    Puerto: $MMDVM_PORT  Baud: $MMDVM_BAUD  Frec: $MMDVM_FREQ Hz"
echo "    Callsign: $MMDVM_CALLSIGN  RC port: $MMDVM_RCPORT"

# 0. Ubuntu 22.04
grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null || warn "No se detecto Ubuntu 22.04. Continuando bajo tu responsabilidad."

# 1. Sistema base ZetronPOC (Asterisk + panel 8080 + cola + worker)
if [[ -d "$APP_DIR" && -f "$APP_DIR/backend/app.py" ]]; then
  log "ZetronPOC base ya instalado en $APP_DIR (salto instalacion base)."
else
  echo "==> 1. Instalando sistema base ZetronPOC (Asterisk + panel 8080)..."
  TMP="mktemp -d"
  if ! curl -fsSL "REPO_BASE" -o "$TMP/instalador.sh"; then
    err "No se pudo descargar instalador.sh base. Verifica internet."; exit 1
  fi
  bash "$TMP/instalador.sh"
  rm -rf "$TMP"
  log "Sistema base ZetronPOC instalado (panel en http://localhost:8080/)."
fi

# 2. Dependencias para compilar MMDVMHost
echo "==> 2. Dependencias para MMDVMHost..."
apt-get update -y
apt-get install -y git build-essential libudev-dev curl ca-certificates

# 3. Clonar y compilar MMDVMHost (G4KLX) + RemoteCommand
echo "==> 3. Compilando MMDVMHost..."
if [[ ! -d "MMDVM_HOST_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/g4klx/MMDVMHost.git "MMDVM_HOST_DIR"
fi
cd "MMDVM_HOST_DIR"
make clean 2>/dev/null || true
make -j"$(nproc)"
[[ -x "MMDVM_HOST_DIR/MMDVMHost" ]] || { err "Fallo la compilacion de MMDVMHost."; exit 1; }
[[ -x "MMDVM_HOST_DIR/RemoteCommand" ]] || { err "Fallo la compilacion de RemoteCommand."; exit 1; }
log "MMDVMHost y RemoteCommand compilados."

# 4. Configuracion MMDVM.ini
echo "==> 4. Generando MMDVM.ini..."
mkdir -p "MMDVM_DIR" /var/log/mmdvm
cat > "MMDVM_DIR/MMDVM.ini" <<EOF
# MMDVM.ini - generado por instalador_mmdvm.sh (ZetronPOC / MediGuard OS)
# Backend serial POCSAG - sin Raspberry, sin .wav

[General]
Callsign=MMDVM_CALLSIGN
Id=2040000
Timeout=180
Duplex=MMDVM_DUPLEX
RFModeHang=10
DMR=0
DSTAR=0
YSF=0
P25=0
NXDN=0
POCSAG=1
Display=None

[Modem]
Port=MMDVM_PORT
BaudeRate=MMDVM_BAUD
TXInvert=MMDVM_TXINVERT
RXInvert=0
PTTInvert=0
TXDelay=100
RXLevel=50
DMRTXLevel=MMDVM_TXLEVEL
DSTAR_TXLevel=MMDVM_TXLEVEL
YSFTXLevel=MMDVM_TXLEVEL
P25TXLevel=MMDVM_TXLEVEL
NXDNTXLevel=MMDVM_TXLEVEL
POCSAGTXLevel=MMDVM_TXLEVEL
TXFrequency=MMDVM_FREQ
RXFrequency=MMDVM_FREQ
TXOffset=0
RXOffset=0
RSSIMapping=0:0,100:100
UseCOSAsLockout=0

[POCSAG]
Enable=1
Callsign=MMDVM_CALLSIGN

[Remote Control]
Enable=1
Port=MMDVM_RCPORT

[DAPNET]
Enable=0

[Display]
Enabled=0
Type=None
Port=MMDVM_PORT

[Info]
Enabled=0

[Log]
DisplayLevel=1
FileLevel=1
FilePath=/var/log/mmdvm
FileRoot=MMDVM
EOF
log "MMDVM.ini en MMDVM_DIR/MMDVM.ini"

# 5. Permisos puerto serie + udev
echo "==> 5. Permisos puerto serie..."
usermod -aG dialout root 2>/dev/null || true
chmod 666 "MMDVM_PORT" 2>/dev/null || warn "Puerto MMDVM_PORT no presente todavia (conecta el modulo y reinicia el servicio)."
cat > /etc/udev/rules.d/99-mmdvm.rules <<'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", SYMLINK+="mmdvm", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", SYMLINK+="mmdvm", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", SYMLINK+="mmdvm", MODE="0666"
EOF
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
log "Reglas udev instaladas (symlink /dev/mmdvm para CP2102/FTDI/CH340)."

# 6. Servicio systemd para MMDVMHost
echo "==> 6. Servicio systemd mmdvmhost..."
cat > /etc/systemd/system/mmdvmhost.service <<EOF
[Unit]
Description=MMDVMHost - Backend POCSAG serial para ZetronPOC
After=network.target
Wants=dev-ttyUSB0.device

[Service]
Type=simple
ExecStart=MMDVM_HOST_DIR/MMDVMHost MMDVM_DIR/MMDVM.ini
WorkingDirectory=MMDVM_HOST_DIR
Restart=always
RestartSec=5
User=root
Environment=TZ=America/Argentina/Cordoba

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mmdvmhost.service 2>/dev/null || true
systemctl restart mmdvmhost.service 2>/dev/null || warn "mmdvmhost no arranco (¿modulo conectado en MMDVM_PORT?). Conectalo y: sudo systemctl start mmdvmhost"
log "Servicio mmdvmhost configurado."

# 7. Puente tx_mmdvm.sh (inyeccion local via Remote Control)
echo "==> 7. Puente tx_mmdvm.sh..."
cat > "APP_DIR/scripts/tx_mmdvm.sh" <<'EOF'
#!/usr/bin/env bash
# tx_mmdvm.sh <RIC> <mensaje> [baud] [rc_port]  -  inyeccion local POCSAG por MMDVMHost Remote Control
set -euo pipefail
RIC="${1:?uso: tx_mmdvm.sh <RIC> <mensaje> [baud] [rc_port]}"
MSG="${2:?falta mensaje}"
BAUD="${3:-1200}"
RC_PORT="${4:-7642}"
RCMD="/opt/MMDVMHost/RemoteCommand"
[[ -x "RCMD" ]] || { echo "[tx_mmdvm] Falta RCMD (compila MMDVMHost)" >&2; exit 1; }
mkdir -p /opt/pocsag-server/logs
echo "[$(date '+%H:%M:%S')] TX MMDVM RIC=RIC MSG=MSG" >> /opt/pocsag-server/logs/mmdvm.log
"RCMD" "RC_PORT" page "RIC" "MSG"
EOF
chmod +x "APP_DIR/scripts/tx_mmdvm.sh"
log "Puente tx_mmdvm.sh instalado."

# 8. Activar backend mmdvm en ZetronPOC (server.conf + DB)
echo "==> 8. Activando backend mmdvm en ZetronPOC..."
CONF="APP_DIR/config/server.conf"
if [[ -f "CONF" ]]; then
  sed -i 's/^ptt_mode.*=.*/ptt_mode      = mmdvm/' "CONF"
  if ! grep -q '^\[mmdvm\]' "CONF"; then
    cat >> "CONF" <<'EOF'

[mmdvm]
ini_path      = /opt/pocsag-server/mmdvm/MMDVM.ini
rc_host       = 127.0.0.1
rc_port       = 7642
serial_port   = /dev/ttyUSB0
baud          = 115200
EOF
  fi
fi
if [[ -f "APP_DIR/database/pocsag.db" ]]; then
  sqlite3 "APP_DIR/database/pocsag.db" "INSERT OR REPLACE INTO config (clave,valor) VALUES ('ptt_mode','mmdvm'),('mmdvm_rc_host','127.0.0.1'),('mmdvm_rc_port','7642');" 2>/dev/null || true
fi
log "server.conf y DB en modo mmdvm."

# 9. Parchear pocsag_handler.py (rama MMDVM, sin .wav)
echo "==> 9. Parcheando pocsag_handler.py (rama MMDVM)..."
HANDLER="APP_DIR/agi/pocsag_handler.py"
python3 - "HANDLER" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "Backend MMDVM" in s:
    print("rama MMDVM ya presente"); raise SystemExit
anchor = "        wavs = []"
if anchor not in s:
    print("anchor no encontrado - revisar manualmente"); raise SystemExit(1)
branch = '''        # --- Backend MMDVM (serial, sin .wav) ---
        if get_config("ptt_mode","gpio") == "mmdvm":
            rc_port = get_config("mmdvm_rc_port","7642")
            tx = "/opt/pocsag-server/scripts/tx_mmdvm.sh"
            for cap in cap_list:
                try:
                    r = subprocess.run([tx, cap, mensaje, str(baudios), rc_port],
                                       capture_output=True, text=True, timeout=30)
                    if r.returncode != 0:
                        log(f"MMDVM fallo cap={cap}: {r.stderr or r.stdout}")
                        registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "mmdvm")
                        fail()
                    registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "mmdvm")
                except Exception as e:
                    log(f"MMDVM excepcion cap={cap}: {e}")
                    registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "mmdvm")
                    fail()
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Envio OK (MMDVM) interno={interno} codigo={codigo} caps={caps} msg={mensaje}")
            return
'''
s = s.replace(anchor, branch + anchor, 1)
open(p, "w").write(s)
print("rama MMDVM insertada")
PYEOF
log "pocsag_handler.py parcheado."

# 10. Reiniciar servicios + verificacion
echo "==> 10. Reiniciando servicios..."
systemctl daemon-reload
systemctl restart pocsag-cola 2>/dev/null || true
systemctl restart pocsag-api 2>/dev/null || true

echo ""
echo "==> Verificacion:"
ok=1
check(){ if systemctl is-active --quiet "$1"; then echo -e "${G}[OK]${NC}   $1"; else echo -e "${R}[FAIL]${NC} $1"; ok=0; fi; }
check mmdvmhost 2>/dev/null || true
check pocsag-api 2>/dev/null || true
check pocsag-cola 2>/dev/null || true
command -v asterisk >/dev/null && echo -e "${G}[OK]${NC}   asterisk" || echo -e "${R}[FAIL]${NC} asterisk"
[[ -x /opt/MMDVMHost/RemoteCommand ]] && echo -e "${G}[OK]${NC}   RemoteCommand" || echo -e "${R}[FAIL]${NC} RemoteCommand"

echo ""
log "Instalacion MMDVM completa."
echo ""
echo "     Panel publico: http://localhost:8080/"
echo "     Panel admin  : http://localhost:8080/admin"
echo "     Modem serial : MMDVM_PORT @ MMDVM_BAUD baud"
echo "     Frecuencia   : MMDVM_FREQ Hz"
echo "     Remote Ctrl  : 127.0.0.1:MMDVM_RCPORT"
echo ""
echo "     Probar POCSAG local (cambiar RIC y mensaje):"
echo "       /opt/pocsag-server/scripts/tx_mmdvm.sh 1234567 \"PRUEBA HOSPITAL\" 1200 MMDVM_RCPORT"
echo ""
echo "     Logs MMDVMHost: sudo journalctl -u mmdvmhost -f"
echo "     Editar config : MMDVM_DIR/MMDVM.ini  (luego: sudo systemctl restart mmdvmhost)"
echo ""
if [[ $ok -eq 0 ]]; then
  warn "Algun servicio fallo. Si el modulo no esta conectado todavia, conectalo y:"
  echo "       sudo systemctl start mmdvmhost"
fi
