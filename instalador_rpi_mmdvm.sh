#!/usr/bin/env bash
# instalador_rpi_mmdvm.sh - Puente MMDVM (serial) para ZetronPOC en RASPBERRY PI
# Usa la UART hardware del header de 40 pines (GPIO 14/15) para la placa MMDVM_HS_HAT
# o un MMDVM conectado al GPIO. POCSAG nativo (sin .wav).
#
# Uso:  curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_rpi_mmdvm.sh | sudo bash
#   o:  sudo bash instalador_rpi_mmdvm.sh
#   o:  sudo bash instalador_rpi_mmdvm.sh --callsign=LU1ABC --port=/dev/serial0 --freq=433.800
# ============================================================================
set -euo pipefail

MMDVM_CALLSIGN="LU1ABC"
MMDVM_PORT="/dev/serial0"
MMDVM_BAUD="115200"
MMDVM_FREQ="433.800"
MMDVM_DUPLEX="0"
MMDVM_TXINVERT="1"
MMDVM_TXLEVEL="50"
MMDVM_RCPORT="7642"

for a in "$@"; do
  case "$a" in
    --callsign=*) MMDVM_CALLSIGN="${a#*=}";;
    --port=*)    MMDVM_PORT="${a#*=}";;
    --baud=*)    MMDVM_BAUD="${a#*=}";;
    --freq=*)    MMDVM_FREQ="${a#*=}";;
    --duplex=*)  MMDVM_DUPLEX="${a#*=}";;
    --invert=*)  MMDVM_TXINVERT="${a#*=}";;
    --level=*)   MMDVM_TXLEVEL="${a#*=}";;
    --rcport=*)  MMDVM_RCPORT="${a#*=}";;
  esac
done

APP_DIR="/opt/zetronpoc"
DB="${APP_DIR}/database/zetronpoc.db"
MMDVM_DIR="${APP_DIR}/mmdvm"
MMDVM_INI="${MMDVM_DIR}/MMDVM.ini"
TX_SCRIPT="${APP_DIR}/scripts/tx_mmdvm.sh"
AGI_HANDLER="${APP_DIR}/agi/pocsag_handler.py"
REPO_BASE="https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; C="\033[1;36m"; NC="\033[0m"
log(){ echo -e "${G}[OK]${NC}  $*"; }
warn(){ echo -e "${Y}[WARN]${NC} $*"; }
err(){ echo -e "${R}[ERR]${NC} $*"; }
note(){ echo -e "${C}[..]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }

# Detectar Raspberry
if [[ ! -f /proc/device-tree/model ]] || ! grep -qi 'raspberry' /proc/device-tree/model 2>/dev/null; then
  warn "Esto no parece una Raspberry Pi. Usar instalador_mmdvm.sh en PC/Ubuntu."
fi

FREQ_HZ=$(awk 'BEGIN{printf "%d", ('"$MMDVM_FREQ"'*1000000)}')

echo "=================================================="
echo " MMDVM Bridge para ZetronPOC  (Raspberry Pi)"
echo "   UART : $MMDVM_PORT @ $MMDVM_BAUD baud (GPIO 14/15)"
echo "   Frec : $MMDVM_FREQ MHz ($FREQ_HZ Hz)"
echo "   Call : $MMDVM_CALLSIGN   RC: $MMDVM_RCPORT"
echo "=================================================="

note "0/9 Verificando instalacion base de ZetronPOC..."
if [[ ! -d "${APP_DIR}" || ! -f "${APP_DIR}/backend/app.py" ]]; then
  warn "No se encontro ZetronPOC en ${APP_DIR}. Instalando la base..."
  curl -fsSL "${REPO_BASE}" | sudo bash
  [[ -d "${APP_DIR}" ]] || { err "Fallo la instalacion base de ZetronPOC."; exit 1; }
fi
log "Base ZetronPOC presente en ${APP_DIR}"

note "1/9 Configurando la UART hardware para el MMDVM..."
CFG="/boot/config.txt"
[[ -f /boot/firmware/config.txt ]] && CFG="/boot/firmware/config.txt"
grep -q '^enable_uart=1' "${CFG}" 2>/dev/null || echo 'enable_uart=1' >> "${CFG}"
grep -q '^dtoverlay=disable-bt' "${CFG}" 2>/dev/null || echo 'dtoverlay=disable-bt' >> "${CFG}"
# liberar la UART del bluetooth
systemctl disable hciuart 2>/dev/null || true
# quitar la consola serie del cmdline
CMD="/boot/cmdline.txt"
[[ -f /boot/firmware/cmdline.txt ]] && CMD="/boot/firmware/cmdline.txt"
[[ -f "${CMD}" ]] && sed -i 's/ console=serial0,[0-9]*//g' "${CMD}"
log "UART habilitada y bluetooth desvinculado (requiere reboot)"

note "2/9 Instalando dependencias de compilacion..."
apt-get update -y
apt-get install -y build-essential git libudev-dev curl ca-certificates netcat-openbsd socat raspberrypi-bootloader 2>/dev/null ||   apt-get install -y build-essential git libudev-dev curl ca-certificates netcat-openbsd socat || true

note "3/9 Compilando MMDVMHost (G4KLX)..."
MMDVMHOST_SRC="/opt/src/MMDVMHost"
if [[ ! -d "${MMDVMHOST_SRC}/.git" ]]; then
  rm -rf "${MMDVMHOST_SRC}"
  git clone --depth 1 https://github.com/g4klx/MMDVMHost "${MMDVMHOST_SRC}" || { err "No se pudo clonar MMDVMHost"; exit 1; }
fi
( cd "${MMDVMHOST_SRC}" && make -j4 )
install -m 0755 "${MMDVMHOST_SRC}/MMDVMHost" /usr/local/bin/MMDVMHost
log "MMDVMHost compilado e instalado"

note "4/9 Generando MMDVM.ini..."
mkdir -p "${MMDVM_DIR}"
cat > "${MMDVM_INI}" <<EOF
# MMDVM.ini - generado por instalador_rpi_mmdvm.sh (ZetronPOC / Raspberry Pi)
# Placa MMDVM por UART hardware (GPIO 14/15), sin .wav

[General]
Callsign=${MMDVM_CALLSIGN}
Id=2040000
Timeout=180
Duplex=${MMDVM_DUPLEX}
RFModeHang=10
DMR=0
DSTAR=0
YSF=0
P25=0
NXDN=0
POCSAG=1
Display=None

[Modem]
Port=${MMDVM_PORT}
BaudeRate=${MMDVM_BAUD}
TXInvert=${MMDVM_TXINVERT}
RXInvert=0
PTTInvert=0
TXDelay=100
RXLevel=50
DMRTXLevel=${MMDVM_TXLEVEL}
DSTAR_TXLevel=${MMDVM_TXLEVEL}
YSFTXLevel=${MMDVM_TXLEVEL}
P25TXLevel=${MMDVM_TXLEVEL}
NXDNTXLevel=${MMDVM_TXLEVEL}
POCSAGTXLevel=${MMDVM_TXLEVEL}
TXFrequency=${FREQ_HZ}
RXFrequency=${FREQ_HZ}
TXOffset=0
RXOffset=0
RSSIMapping=0:0,100:100
UseCOSAsLockout=0

[POCSAG]
Enable=1
Callsign=${MMDVM_CALLSIGN}

[Remote Control]
Enable=1
Port=${MMDVM_RCPORT}

[DAPNET]
Enable=0

[Display]
Enabled=0
Type=None
Port=${MMDVM_PORT}

[Info]
Enabled=0

[Log]
DisplayLevel=1
FileLevel=1
FilePath=/var/log/mmdvm
FileRoot=MMDVM
EOF
log "MMDVM.ini en ${MMDVM_INI}"

note "5/9 Creando servicio systemd mmdvmhost..."
cat > /etc/systemd/system/mmdvmhost.service <<EOF
[Unit]
Description=MMDVMHost (POCSAG serial encoder para ZetronPOC)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/MMDVMHost ${MMDVM_INI}
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /var/log/mmdvm
systemctl daemon-reload
systemctl enable mmdvmhost
log "Servicio mmdvmhost creado (se inicia tras reboot)"

note "6/9 Creando puente POCSAG -> MMDVM (RemoteCommand)..."
mkdir -p "${APP_DIR}/scripts"
cat > "${TX_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# tx_mmdvm.sh <RIC> <mensaje> [baudios] - inyecta POCSAG al MMDVM por RemoteControl.
set -euo pipefail
RIC="${1:?uso: tx_mmdvm.sh RIC 'mensaje' [baudios]}"
MSG="${2:?falta mensaje}"
BAUD="${3:-1200}"
RC_PORT="$(awk -F= '/^Port/{print $2}' /opt/zetronpoc/mmdvm/MMDVM.ini | tail -1 | tr -d ' ')"
RC_PORT="${RC_PORT:-7642}"
echo "Sending message: \"$MSG\" to $RIC at $BAUD bps" | nc -w 2 127.0.0.1 "${RC_PORT}" || \
  echo "Sending message: \"$MSG\" to $RIC at $BAUD bps" | socat - TCP:127.0.0.1:${RC_PORT}
EOF
chmod +x "${TX_SCRIPT}"
log "Puente en ${TX_SCRIPT}"

note "7/9 Adaptando el AGI para modo MMDVM..."
patch_agi() {
  local f="$1"
  [[ -f "$f" ]] || return
  if ! grep -q 'mmdvm' "$f"; then
    python3 - "$f" <<'PYEOF'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = "        wavs = []"
if "mmdvm" in s or anchor not in s:
    sys.exit(0)
inj = '''        if get_config("ptt_mode", "gpio") == "mmdvm":
            rc_host = get_config("mmdvm_rc_host", "127.0.0.1")
            rc_port = get_config("mmdvm_rc_port", "7642")
            tx = os.path.join(APP_DIR, "scripts", "tx_mmdvm.sh")
            for cap in cap_list:
                subprocess.run([tx, cap, mensaje, str(baudios)], timeout=15,
                                capture_output=True, text=True)
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "mmdvm")
            log("Envio OK (MMDVM) codigo=%s caps=%s msg=%s" % (codigo, caps, mensaje))
            return
'''
s = s.replace(anchor, inj + anchor, 1)
open(f, "w").write(s)
PYEOF
    log "AGI parchado: $f"
  fi
}
patch_agi "${AGI_HANDLER}"
[[ -f /var/lib/asterisk/agi-bin/pocsag_handler.py ]] && cp "${AGI_HANDLER}" /var/lib/asterisk/agi-bin/pocsag_handler.py

note "8/9 Seteando modo MMDVM en la base de ZetronPOC..."
sqlite3 "${DB}" "INSERT OR REPLACE INTO config (clave,valor) VALUES
 ('ptt_mode','mmdvm'),
 ('mmdvm_rc_host','127.0.0.1'),
 ('mmdvm_callsign','${MMDVM_CALLSIGN}'),
 ('mmdvm_serial_port','${MMDVM_PORT}'),
 ('mmdvm_baud','${MMDVM_BAUD}'),
 ('mmdvm_frequency','${MMDVM_FREQ}'),
 ('mmdvm_duplex','${MMDVM_DUPLEX}'),
 ('mmdvm_pocsag_baud','1200'),
 ('mmdvm_tx_invert','${MMDVM_TXINVERT}'),
 ('mmdvm_tx_level','${MMDVM_TXLEVEL}'),
 ('mmdvm_rc_port','${MMDVM_RCPORT}'),
 ('mmdvm_display','None');" 2>/dev/null || warn "No se pudo escribir config en la BD"
systemctl restart zetronpoc-cola 2>/dev/null || true
systemctl restart zetronpoc-api 2>/dev/null || true
log "Modo MMDVM activado en la BD"

note "9/9 Chequeo final..."
echo "  UART config:"
grep -E '^enable_uart|^dtoverlay=disable-bt' "${CFG}" 2>/dev/null | sed 's/^/    /' || true
echo "  MMDVM.ini port: $(awk -F= '/^Port/{print $2}' "${MMDVM_INI}" | head -1)"
echo ""
log "Puente MMDVM (Raspberry Pi) instalado."
echo ""
echo "  ⚠ IMPORTANTE: Hay que REINICIAR la Raspberry para que la UART quede libre:"
echo "       sudo reboot"
echo ""
echo "  Despues del reboot:"
echo "    1) sudo systemctl start mmdvmhost   (o ya inicia solo)"
echo "    2) Conecta el MMDVM al header GPIO 14(TX)/15(RX)/GND/5V"
echo "    3) Ajusta frecuencia/nivel en panel admin -> Parametros -> MMDVM"
echo "    4) Prueba local (sin DAPNET, sin .wav):"
echo "       ${TX_SCRIPT} 1234567 'PRUEBA HOSPITAL' 1200"
echo "    5) Logs en vivo:  sudo journalctl -u mmdvmhost -f"
echo ""
echo "  La placa transmite POCSAG nativo por la UART del GPIO."
