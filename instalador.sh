#!/usr/bin/env bash
# ============================================================================
# instalador.sh  —  Sistema de Paginación Hospitalaria POCSAG sobre VoIP
# ============================================================================
# ÚNICO ARCHIVO. Contiene todo el sistema embebido.
# Uso:    sudo bash instalador.sh
# Quita:  sudo /opt/pocsag-server/bin/uninstall.sh  (o --purge)
# ============================================================================
set -euo pipefail

APP_DIR="/opt/pocsag-server"
AST_USER="asterisk"
LOG_FILE="/var/log/pocsag-install.log"

G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; NC="\033[0m"
log()  { echo -e "${G}[OK]${NC}   $*"; }
warn() { echo -e "${Y}[WARN]${NC} $*"; }
err()  { echo -e "${R}[ERR]${NC}  $*" >&2; }

# ============================ PRECHEQUEOS ====================================
[[ $EUID -ne 0 ]] && { err "Ejecutá como root o con sudo."; exit 1; }
grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null || warn "No se detectó Ubuntu 22.04. Continuando bajo tu responsabilidad."

mkdir -p "${LOG_FILE%/*}"
exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "==> Instalando sistema POCSAG en ${APP_DIR}"

# ============================ 1. PAQUETES ====================================
echo "==> 1/8 Instalando dependencias..."
apt-get update -y
apt-get install -y asterisk sqlite3 python3 python3-pip alsa-utils sox git \
  libgpiod2 gpiod curl ca-certificates logrotate espeak zip
pip3 install --break-system-packages pocsag 2>/dev/null || warn "No se pudo instalar python-pocsag (revisar manualmente)"

# ============================ 2. ESTRUCTURA =================================
echo "==> 2/8 Creando estructura..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs,bin}

# ============================ 3. ARCHIVOS ===================================
write_file() { mkdir -p "$(dirname "$1")"; cat > "$1"; chmod "${3:-644}" "$2"; }
mkx() { chmod +x "$1"; }

# --- config/server.conf ---
cat > "${APP_DIR}/config/server.conf" <<'EOF'
[general]
app_dir       = /opt/pocsag-server
db_path       = /opt/pocsag-server/database/pocsag.db
log_file      = /opt/pocsag-server/logs/pocsag.log
audio_dir     = /opt/pocsag-server/audio

[asterisk]
agi_bin       = /var/lib/asterisk/agi-bin
sounds_dir    = /var/lib/asterisk/sounds
intern        = 2184
incoming_ctx  = pocsag-incoming

[radio]
ptt_mode      = gpio
gpio_chip     = gpiochip4
gpio_pin      = 17
default_baud  = 1200
deviation_khz = 4.5
audio_device  = plughw:0,0

[encoder]
backend       = python
sample_rate   = 22050

[backend_api]
host          = 127.0.0.1
port          = 8080
EOF

# --- database/schema.sql ---
cat > "${APP_DIR}/database/schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS codigos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  tipo TEXT NOT NULL,
  cap_code TEXT,
  baudios INTEGER DEFAULT 1200,
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre TEXT UNIQUE NOT NULL,
  cap_code TEXT,
  baudios INTEGER DEFAULT 1200
);
CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
  cap_code TEXT NOT NULL,
  PRIMARY KEY (grupo_id, cap_code)
);
CREATE TABLE IF NOT EXISTS bitacora (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora DATETIME DEFAULT CURRENT_TIMESTAMP,
  interno_origen TEXT,
  codigo TEXT,
  cap_code TEXT,
  mensaje TEXT,
  baudios INTEGER,
  estado TEXT,
  observaciones TEXT
);
CREATE INDEX IF NOT EXISTS idx_bitacora_fecha ON bitacora(fecha_hora);
CREATE INDEX IF NOT EXISTS idx_codigos_codigo ON codigos(codigo);
EOF

# --- database/seed.sql ---
cat > "${APP_DIR}/database/seed.sql" <<'EOF'
INSERT OR IGNORE INTO codigos (codigo,tipo,cap_code,baudios,descripcion) VALUES
 ('11','grupo','100001',1200,'Código Azul (paro cardíaco)'),
 ('12','broadcast','200001',1200,'Código Rojo (incendio)'),
 ('13','broadcast','200002',1200,'Código Blanco (evacuación)'),
 ('21','individual','300021',1200,'Médico de guardia'),
 ('22','individual','300022',1200,'Enfermero de guardia'),
 ('99','individual','300099',512,'Prueba de sistema');
INSERT OR IGNORE INTO grupos (nombre,cap_code,baudios) VALUES
 ('Guardia médica','100001',1200), ('Emergencias','200001',1200);
INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code) VALUES
 (1,'300021'), (1,'300022'), (2,'300021'), (2,'300022');
EOF

# --- database/db_manager.py ---
cat > "${APP_DIR}/database/db_manager.py" <<'EOF'
#!/usr/bin/env python3
import sqlite3, os
from contextlib import contextmanager
DEFAULT_DB = "/opt/pocsag-server/database/pocsag.db"

@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path); conn.row_factory = sqlite3.Row
    try: yield conn; conn.commit()
    finally: conn.close()

def init_db(db_path=DEFAULT_DB):
    base = os.path.dirname(__file__)
    with get_conn(db_path) as conn:
        with open(os.path.join(base,"schema.sql")) as f: conn.executescript(f.read())
        with open(os.path.join(base,"seed.sql")) as f: conn.executescript(f.read())

def resolver_codigo(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT cap_code, baudios, tipo FROM codigos WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        return tuple(row) if row else None

def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO bitacora (interno_origen,codigo,cap_code,mensaje,baudios,estado) VALUES (?,?,?,?,?,?)",
                     (interno,codigo,cap_code,mensaje,baudios,estado))

def listar_codigos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM codigos ORDER BY codigo")]

def bitacora_reciente(limit=20, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM bitacora ORDER BY id DESC LIMIT ?",(limit,))]

def crear_codigo(codigo, tipo, cap_code, baudios, descripcion, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT OR IGNORE INTO codigos (codigo,tipo,cap_code,baudios,descripcion) VALUES (?,?,?,?,?)",
                     (codigo,tipo,cap_code,baudios,descripcion))

def actualizar_codigo(codigo, tipo, cap_code, baudios, descripcion, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE codigos SET tipo=?,cap_code=?,baudios=?,descripcion=?,activo=? WHERE codigo=?",
                     (tipo,cap_code,baudios,descripcion,activo,codigo))

def borrar_codigo(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM codigos WHERE codigo=?",(codigo,))

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    import subprocess, sys
    destino = resolver_codigo(codigo, db_path)
    if not destino: return {"status":"error","detalle":"código no encontrado"}
    cap_code, baudios, tipo = destino
    handler = "/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler = "/opt/pocsag-server/agi/pocsag_handler.py"
    rc = subprocess.run([sys.executable, handler, origen, codigo, mensaje], capture_output=True, text=True)
    if rc.returncode == 0: return {"status":"enviado","cap_code":cap_code,"baudios":baudios}
    return {"status":"error","detalle":rc.stderr.strip() or "falló el envío"}

if __name__ == "__main__":
    import sys
    if len(sys.argv)>1 and sys.argv[1]=="init": init_db(); print("Base de datos inicializada.")
EOF
mkx "${APP_DIR}/database/db_manager.py"

# --- asterisk/extensions_pocsag.conf ---
cat > "${APP_DIR}/asterisk/extensions_pocsag.conf" <<'EOF'
[pocsag-incoming]
exten => 2184,1,NoOp(=== Paginación hospitalaria ===)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=20)
 same => n,Playback(marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${CODE}" = ""]?fin:error)
 same => n,Playback(marque-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,8)
 same => n,GotoIf($["${MESSAGE}" = ""]?fin:error2)
 same => n,AGI(pocsag_handler.py,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,GotoIf($["${AGISTATUS}" = "SUCCESS"]?ok:fail)
 same => n(ok),Playback(confirmado)
 same => n(fin),Hangup()
 same => n(fail),Playback(error-envio)
 same => n,Hangup()
 same => n(error),Playback(codigo-invalido)
 same => n,Hangup()
 same => n(error2),Playback(mensaje-invalido)
 same => n,Hangup()
EOF

# --- asterisk/pjsip_pocsag.conf ---
cat > "${APP_DIR}/asterisk/pjsip_pocsag.conf" <<'EOF'
[pocsag-endpoint]
type=endpoint
context=pocsag-incoming
disallow=all
allow=ulaw,alaw
transport=transport-udp
auth=pocsag-auth
aors=pocsag-aor

[pocsag-auth]
type=auth
auth_type=userpass
username=2184
password=CAMBIAR_PASSWORD_2184

[pocsag-aor]
type=aor
max_contacts=1
EOF

# --- asterisk/modules.conf ---
cat > "${APP_DIR}/asterisk/modules.conf" <<'EOF'
[modules]
autoload=yes
load => app_playback.so
load => app_read.so
load => res_agi.so
load => chan_pjsip.so
load => codec_ulaw.so
load => codec_alaw.so
load => format_gsm.so
load => format_wav.so
EOF

# --- agi/pocsag_handler.py ---
cat > "${APP_DIR}/agi/pocsag_handler.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, subprocess, traceback
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_codigo, registrar_bitacora

AUDIO_DIR = "/opt/pocsag-server/audio"
PTT_ON = "/opt/pocsag-server/scripts/ptt_on.sh"
PTT_OFF = "/opt/pocsag-server/scripts/ptt_off.sh"
ENCODER = "/opt/pocsag-server/encoder/pocsag_gen.py"

def log(msg):
    with open("/opt/pocsag-server/logs/pocsag.log","a") as f: f.write(f"[AGI] {msg}\n")

def fail():
    sys.stdout.write("SET VARIABLE AGISTATUS FAILURE\n"); sys.stdout.flush(); sys.exit(0)

def main():
    try:
        interno = sys.argv[1] if len(sys.argv)>1 else "unknown"
        codigo = sys.argv[2] if len(sys.argv)>2 else ""
        mensaje = sys.argv[3] if len(sys.argv)>3 else ""
        if not codigo or not mensaje: fail()
        destino = resolver_codigo(codigo)
        if not destino: log(f"Código no encontrado: {codigo}"); fail()
        cap_code, baudios, tipo = destino
        wav = os.path.join(AUDIO_DIR, f"out_{cap_code}.wav")
        rc = subprocess.run([sys.executable, ENCODER, cap_code, mensaje, str(baudios), wav], capture_output=True, text=True)
        if rc.returncode != 0:
            log(f"Encoder falló: {rc.stderr}")
            registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, "error", "encoder")
            fail()
        subprocess.run([PTT_ON], check=True)
        subprocess.run(["aplay","-q",wav], check=True)
        subprocess.run([PTT_OFF], check=True)
        registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, "enviado")
        sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
        log(f"Envío OK interno={interno} codigo={codigo} cap={cap_code} msg={mensaje}")
    except Exception as e:
        log(f"Excepción: {e}\n{traceback.format_exc()}"); fail()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_handler.py"

# --- encoder/pocsag_gen.py ---
cat > "${APP_DIR}/encoder/pocsag_gen.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, subprocess
def encode_python(cap_code, mensaje, baudios, salida):
    try: from pocsag import encode
    except ImportError: print("Falta 'pocsag': pip3 install pocsag", file=sys.stderr); return 1
    encode(salida, [(int(cap_code),"N",mensaje)], baud=baudios); return 0
def main():
    if len(sys.argv)!=5: print("Uso: pocsag_gen.py <cap> <msg> <baud> <out.wav>", file=sys.stderr); return 1
    cap,msg,baud,out = sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
    return encode_python(cap,msg,baud,out)
if __name__=="__main__": sys.exit(main())
EOF
mkx "${APP_DIR}/encoder/pocsag_gen.py"

# --- encoder/modulator.sh ---
cat > "${APP_DIR}/encoder/modulator.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CAP="${1:?cap}"; MSG="${2:?msg}"; BAUD="${3:?baud}"; OUT="${4:?out}"
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "${BASE}/encoder/pocsag_gen.py" "$CAP" "$MSG" "$BAUD" "$OUT"
EOF
mkx "${APP_DIR}/encoder/modulator.sh"

# --- scripts/ptt_on.sh ---
cat > "${APP_DIR}/scripts/ptt_on.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CHIP="gpiochip4"; PIN="17"
if [[ -c /dev/ttyUSB0 ]]; then stty -F /dev/ttyUSB0 9600 2>/dev/null||true; echo -n 'ON' >/dev/ttyUSB0
elif command -v gpioset >/dev/null; then gpioset "${CHIP}" "${PIN}=1"
else echo "[ptt_on] Configurar GPIO o ttyUSB0" >&2; exit 1; fi
EOF
mkx "${APP_DIR}/scripts/ptt_on.sh"

# --- scripts/ptt_off.sh ---
cat > "${APP_DIR}/scripts/ptt_off.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CHIP="gpiochip4"; PIN="17"
if [[ -c /dev/ttyUSB0 ]]; then stty -F /dev/ttyUSB0 9600 2>/dev/null||true; echo -n 'OFF' >/dev/ttyUSB0
elif command -v gpioset >/dev/null; then gpioset "${CHIP}" "${PIN}=0"
else echo "[ptt_off] Configurar GPIO o ttyUSB0" >&2; exit 1; fi
EOF
mkx "${APP_DIR}/scripts/ptt_off.sh"

# --- scripts/healthcheck.sh ---
cat > "${APP_DIR}/scripts/healthcheck.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ok=1
check(){ if systemctl is-active --quiet "$1"; then echo "[OK]   $1"; else echo "[FAIL] $1"; ok=0; fi; }
check asterisk; check pocsag-monitor; check pocsag-api 2>/dev/null||true
command -v aplay>/dev/null&&echo "[OK]   aplay"||{ echo "[FAIL] aplay"; ok=0; }
command -v sqlite3>/dev/null&&echo "[OK]   sqlite3"||{ echo "[FAIL] sqlite3"; ok=0; }
command -v python3>/dev/null&&echo "[OK]   python3"||{ echo "[FAIL] python3"; ok=0; }
python3 -c "import pocsag" 2>/dev/null&&echo "[OK]   python-pocsag"||echo "[WARN] python-pocsag"
[[ $ok -eq 1 ]]&&echo "Sistema POCSAG: SALUDABLE"||echo "Sistema POCSAG: REVISAR"
exit $((1-ok))
EOF
mkx "${APP_DIR}/scripts/healthcheck.sh"

# --- services/pocsag-monitor.service ---
cat > "${APP_DIR}/services/pocsag-monitor.service" <<'EOF'
[Unit]
Description=Monitor del sistema de paginación POCSAG
After=asterisk.service network.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'while true; do systemctl is-active --quiet asterisk || systemctl restart asterisk; /opt/pocsag-server/scripts/healthcheck.sh >> /opt/pocsag-server/logs/health.log 2>&1; sleep 30; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- services/pocsag-api.service ---
cat > "${APP_DIR}/services/pocsag-api.service" <<'EOF'
[Unit]
Description=API de gestión del sistema POCSAG
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/pocsag-server/backend
ExecStart=/usr/bin/python3 /opt/pocsag-server/backend/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

# --- backend/app.py ---
cat > "${APP_DIR}/backend/app.py" <<'EOF'
#!/usr/bin/env python3
import os, sys, json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import listar_codigos, bitacora_reciente, crear_codigo, actualizar_codigo, borrar_codigo, enviar_mensaje

HOST=os.environ.get("POCSAG_API_HOST","0.0.0.0")
PORT=int(os.environ.get("POCSAG_API_PORT","8080"))
FRONT="/opt/pocsag-server/frontend"

def jr(h,d,c=200):
    b=json.dumps(d,ensure_ascii=False).encode()
    h.send_response(c); h.send_header("Content-Type","application/json; charset=utf-8")
    h.send_header("Content-Length",str(len(b))); h.end_headers(); h.wfile.write(b)

class H(BaseHTTPRequestHandler):
    def _body(self):
        n=int(self.headers.get("Content-Length",0))
        return json.loads(self.rfile.read(n)) if n else {}
    def do_GET(self):
        if self.path=="/api/codigos": return jr(self,listar_codigos())
        if self.path=="/api/bitacora": return jr(self,bitacora_reciente(50))
        if self.path=="/api/health": return jr(self,{"status":"ok"})
        if self.path in ("/","/index.html"):
            f=os.path.join(FRONT,"index.html")
            if os.path.exists(f):
                self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
                with open(f,"rb") as fh: self.wfile.write(fh.read()); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        try:
            d=self._body()
            if self.path=="/api/enviar":
                return jr(self, enviar_mensaje(d.get("codigo",""), d.get("mensaje",""), d.get("origen","web")))
            if self.path=="/api/codigos":
                crear_codigo(d.get("codigo",""), d.get("tipo","individual"), d.get("cap_code",""), int(d.get("baudios",1200)), d.get("descripcion",""))
                return jr(self,{"status":"ok"})
            if self.path=="/api/codigos/update":
                actualizar_codigo(d.get("codigo",""), d.get("tipo","individual"), d.get("cap_code",""), int(d.get("baudios",1200)), d.get("descripcion",""), int(d.get("activo",1)))
                return jr(self,{"status":"ok"})
            if self.path=="/api/codigos/delete":
                borrar_codigo(d.get("codigo",""))
                return jr(self,{"status":"ok"})
            self.send_response(404); self.end_headers()
        except Exception as e:
            return jr(self,{"status":"error","detalle":str(e)},500)
    def do_OPTIONS(self):
        self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type"); self.end_headers()
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
EOF
mkx "${APP_DIR}/backend/app.py"

# --- frontend/index.html ---
cat > "${APP_DIR}/frontend/index.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG</title>
<style>body{font-family:system-ui;margin:0;background:#0f172a;color:#e2e8f0}
header{background:#1e293b;padding:1rem 2rem;border-bottom:1px solid #334155;display:flex;justify-content:space-between;align-items:center}
h1{margin:0;font-size:1.25rem}main{padding:2rem;display:grid;gap:1.5rem;max-width:1100px;margin:auto}
.card{background:#1e293b;border:1px solid #334155;border-radius:.5rem;padding:1.25rem}
.card h2{margin-top:0;font-size:1rem;color:#38bdf8}table{width:100%;border-collapse:collapse;font-size:.85rem}
th,td{text-align:left;padding:.5rem;border-bottom:1px solid #334155}th{color:#94a3b8}
.badge{padding:.15rem .5rem;border-radius:9999px;font-size:.7rem;background:#334155}
.ok{background:#064e3b;color:#6ee7b7}.err{background:#7f1d1d;color:#fca5a5}
input,select,button{font-family:inherit;font-size:.9rem;padding:.4rem .6rem;border-radius:.4rem;border:1px solid #334155;background:#0f172a;color:#e2e8f0}
button{cursor:pointer;border:none}button:disabled{opacity:.5}
.btn-env{background:#2563eb}.btn-env:hover{background:#3b82f6}.btn-del{background:#b91c1c}.btn-del:hover{background:#dc2626}
.btn-edit{background:#475569}.btn-edit:hover{background:#64748b}.btn-save{background:#059669}.btn-save:hover{background:#10b981}
.row{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center;margin-bottom:.5rem}
.row label{min-width:80px;color:#94a3b8;font-size:.8rem}
.toast{position:fixed;bottom:1rem;right:1rem;padding:.75rem 1rem;border-radius:.5rem;background:#1e293b;border:1px solid #334155;opacity:0;transition:opacity .3s}
.toast.show{opacity:1}td.act{display:flex;gap:.25rem}</style></head>
<body><header><h1>🏥 Paginación POCSAG</h1><span id="h" class="badge">…</span></header>
<main>
<section class="card"><h2>Enviar mensaje</h2>
<div class="row"><label>Código</label><select id="e_cod" style="flex:1"></select></div>
<div class="row"><label>Mensaje</label><input id="e_msg" style="flex:1" placeholder="Texto alfanumérico"></div>
<div class="row"><button class="btn-env" onclick="enviar()">Enviar a pager</button></div>
</section>
<section class="card"><h2 id="ft">Crear código</h2>
<div class="row"><label>Código</label><input id="f_cod" style="width:90px" placeholder="ej 23"><label>Tipo</label><select id="f_tipo"><option value="individual">individual</option><option value="grupo">grupo</option><option value="broadcast">broadcast</option></select></div>
<div class="row"><label>Cap Code</label><input id="f_cap" style="width:140px" placeholder="ej 300023"><label>Baudios</label><select id="f_baud"><option>1200</option><option>512</option><option>2400</option></select></div>
<div class="row"><label>Desc</label><input id="f_desc" style="flex:1" placeholder="descripción"></div>
<div class="row" id="f_act_wrap" style="display:none"><label>Activo</label><select id="f_act"><option value="1">sí</option><option value="0">no</option></select></div>
<div class="row"><button class="btn-save" id="f_btn" onclick="guardar()">Crear</button><button id="f_cancel" style="display:none" onclick="resetForm()">Cancelar</button></div>
</section>
<section class="card"><h2>Códigos</h2><table><thead><tr><th>Código</th><th>Tipo</th><th>Cap</th><th>Baud</th><th>Desc</th><th>Act</th><th></th></tr></thead>
<tbody id="cod"></tbody></table></section>
<section class="card"><h2>Bitácora</h2><table><thead><tr><th>Fecha</th><th>Interno</th><th>Código</th><th>Cap</th><th>Msg</th><th>Estado</th></tr></thead>
<tbody id="bit"></tbody></table></section></main>
<div class="toast" id="t"></div>
<script>
const g=u=>fetch(u).then(r=>r.json());
const p=(u,d)=>fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(d)}).then(r=>r.json());
const toast=m=>{const t=document.getElementById('t');t.textContent=m;t.classList.add('show');setTimeout(()=>t.classList.remove('show'),2500);};
const badge=e=>e==='enviado'?`<span class="badge ok">${e}</span>`:`<span class="badge err">${e||'-'}</span>`;
let editing=null;
async function enviar(){
  const codigo=document.getElementById('e_cod').value, mensaje=document.getElementById('e_msg').value.trim();
  if(!codigo||!mensaje) return toast('Elegí código y mensaje');
  const r=await p('/api/enviar',{codigo,mensaje,origen:'web'});
  toast(r.status==='enviado'?`Enviado a ${r.cap_code}`:`Error: ${r.detalle||''}`);
  cargarBitacora();
}
function editar(c){const x=codigos.find(o=>o.codigo===c);if(!x)return;editing=c;
  document.getElementById('ft').textContent='Modificar código '+c;
  document.getElementById('f_cod').value=x.codigo;document.getElementById('f_cod').disabled=true;
  document.getElementById('f_tipo').value=x.tipo;document.getElementById('f_cap').value=x.cap_code||'';
  document.getElementById('f_baud').value=String(x.baudios);document.getElementById('f_desc').value=x.descripcion||'';
  document.getElementById('f_act').value=String(x.activo);document.getElementById('f_act_wrap').style.display='flex';
  document.getElementById('f_btn').textContent='Guardar';document.getElementById('f_cancel').style.display='inline-block';}
function resetForm(){editing=null;
  document.getElementById('ft').textContent='Crear código';document.getElementById('f_cod').disabled=false;
  document.getElementById('f_cod').value='';document.getElementById('f_tipo').value='individual';
  document.getElementById('f_cap').value='';document.getElementById('f_baud').value='1200';
  document.getElementById('f_desc').value='';document.getElementById('f_act_wrap').style.display='none';
  document.getElementById('f_btn').textContent='Crear';document.getElementById('f_cancel').style.display='none';}
async function guardar(){
  const d={codigo:document.getElementById('f_cod').value.trim(),tipo:document.getElementById('f_tipo').value,
    cap_code:document.getElementById('f_cap').value.trim(),baudios:document.getElementById('f_baud').value,
    descripcion:document.getElementById('f_desc').value.trim(),activo:document.getElementById('f_act').value};
  if(!d.codigo) return toast('Falta código');
  if(editing){await p('/api/codigos/update',d);toast('Actualizado');}else{await p('/api/codigos',d);toast('Creado');}
  resetForm();cargarCodigos();}
async function borrar(c){if(!confirm('Borrar código '+c+'?'))return;await p('/api/codigos/delete',{codigo:c});cargarCodigos();}
let codigos=[];
async function cargarCodigos(){codigos=await g('/api/codigos');
  document.getElementById('cod').innerHTML=codigos.map(x=>`<tr><td>${x.codigo}</td><td>${x.tipo}</td><td>${x.cap_code||''}</td><td>${x.baudios}</td><td>${x.descripcion||''}</td><td>${x.activo?'✅':'⬛'}</td><td class="act"><button class="btn-edit" onclick="editar('${x.codigo}')">Editar</button><button class="btn-del" onclick="borrar('${x.codigo}')">Borrar</button></td></tr>`).join('');
  const s=document.getElementById('e_cod');s.innerHTML=codigos.map(x=>`<option value="${x.codigo}">${x.codigo} — ${x.descripcion||x.tipo}</option>`).join('');}
async function cargarBitacora(){const b=await g('/api/bitacora');
  document.getElementById('bit').innerHTML=b.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${badge(x.estado)}</td></tr>`).join('');}
(async()=>{try{const h=await g('/api/health');document.getElementById('h').textContent=h.status==='ok'?'en línea':'caído';}catch(e){document.getElementById('h').textContent='caído';}
cargarCodigos();cargarBitacora();})();
</script></body></html>
EOF

# --- bin/uninstall.sh ---
cat > "${APP_DIR}/bin/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP="/opt/pocsag-server"; PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1
[[ $EUID -ne 0 ]] && { echo "root/sudo"; exit 1; }
systemctl disable --now pocsag-monitor pocsag-api 2>/dev/null||true
systemctl stop asterisk 2>/dev/null||true
rm -f /etc/systemd/system/pocsag-{monitor,api}.service
systemctl daemon-reload
rm -f /etc/asterisk/extensions_pocsag.conf /etc/asterisk/pjsip_pocsag.conf
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py
rm -f /etc/logrotate.d/pocsag
if [[ $PURGE -eq 1 ]]; then rm -rf "$APP"; rm -f /var/log/pocsag-install.log
else cp "$APP/database/pocsag.db" /tmp/pocsag-backup.db 2>/dev/null||true; rm -rf "$APP"; fi
echo "Desinstalación completa (Asterisk y deps NO se quitan)."
EOF
mkx "${APP_DIR}/bin/uninstall.sh"

# --- README ---
cat > "${APP_DIR}/README.md" <<'EOF'
# Sistema POCSAG - Paginación hospitalaria sobre VoIP
Instalado en /opt/pocsag-server por: sudo bash instalador.sh
Desinstalar: sudo /opt/pocsag-server/bin/uninstall.sh  (o --purge)
Flujo: marcar 2184 -> código -> pip -> mensaje -> pip -> POCSAG -> TX VHF/HF
Próximos pasos: ajustar scripts/ptt_on.sh (GPIO real), password en asterisk/pjsip_pocsag.conf, calibrar desviación ±4.5kHz.
EOF

chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}"

# ============================ 4. BASE DE DATOS ==============================
echo "==> 3/8 Inicializando base de datos..."
python3 "${APP_DIR}/database/db_manager.py" init
chmod 640 "${APP_DIR}/database/pocsag.db" 2>/dev/null || true

# ============================ 5. ASTERISK ==================================
echo "==> 4/8 Configurando Asterisk..."
AST_ETC="/etc/asterisk"
cp "${APP_DIR}/asterisk/extensions_pocsag.conf" "${AST_ETC}/"
cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${AST_ETC}/"
cp "${APP_DIR}/asterisk/modules.conf" "${AST_ETC}/"
grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"
grep -q 'pjsip_pocsag.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_pocsag.conf' >> "${AST_ETC}/pjsip.conf"

# ============================ 6. AGI ======================================
echo "==> 5/8 Instalando AGI..."
mkdir -p /var/lib/asterisk/agi-bin
cp "${APP_DIR}/agi/pocsag_handler.py" /var/lib/asterisk/agi-bin/
mkx /var/lib/asterisk/agi-bin/pocsag_handler.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin

# ============================ 7. LOCUCIONES ==============================
echo "==> 6/8 Generando locuciones IVR..."
gen(){ local out="${APP_DIR}/audio/$1.gsm"; [[ -f "$out" ]] && return
  espeak -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null || warn "No se pudo generar $1"
  rm -f "${out%.gsm}.wav"; }
gen marque-codigo "Marque su numero de codigo"
gen marque-mensaje "Marque su mensaje"
gen confirmado "Mensaje enviado"
gen error-envio "Error de envio"
gen codigo-invalido "Codigo invalido"
gen mensaje-invalido "Mensaje invalido"
sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null || warn "beep no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds/ 2>/dev/null || true

# ============================ 8. SYSTEMD + LOGROTATE =====================
echo "==> 7/8 Servicios systemd + logrotate..."
cp "${APP_DIR}/services/"*.service /etc/systemd/system/
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
systemctl enable --now pocsag-monitor 2>/dev/null || true
systemctl enable --now pocsag-api 2>/dev/null || warn "API no pudo activarse"

# ============================ 9. RECARGA + CHEQUEO =======================
echo "==> 8/8 Recargando y chequeando..."
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
bash "${APP_DIR}/scripts/healthcheck.sh" || warn "Healthcheck reportó problemas"

echo "--------------------------------------------"
log "Instalación completada en ${APP_DIR}"
cat <<'EOF'

PROXIMOS PASOS:
  1. Editar /opt/pocsag-server/scripts/ptt_on.sh y ptt_off.sh (pin GPIO real).
  2. Cambiar el password en /etc/asterisk/pjsip_pocsag.conf (interno 2184).
  3. Calibrar nivel de audio y desviación del TX (±4.5 kHz POCSAG).
  4. Registrar un SIP en contexto pocsag-incoming y marcar 2184 para probar.
  5. Panel web:  http://<servidor>:8080/
  6. Bitácora:   sqlite3 /opt/pocsag-server/database/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

Desinstalar: sudo /opt/pocsag-server/bin/uninstall.sh
EOF