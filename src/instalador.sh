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
echo "==> 1/9 Instalando dependencias..."
apt-get update -y
apt-get install -y asterisk sqlite3 python3 python3-pip alsa-utils sox git \
  libgpiod2 gpiod curl ca-certificates logrotate espeak zip
pip3 install --break-system-packages pocsag 2>/dev/null || warn "No se pudo instalar python-pocsag (revisar manualmente)"

# ============================ 2. ESTRUCTURA =================================
echo "==> 2/9 Creando estructura..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs,bin}

# ============================ 3. ARCHIVOS ===================================
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
host          = 0.0.0.0
port          = 8080
EOF

# --- database/schema.sql ---
cat > "${APP_DIR}/database/schema.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS pagers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  cap_code TEXT NOT NULL,
  nombre TEXT,
  apellido TEXT,
  area TEXT,
  baudios INTEGER DEFAULT 1200,
  tipo TEXT DEFAULT 'individual',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  nombre TEXT,
  baudios INTEGER DEFAULT 1200,
  activo INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
  cap_code TEXT NOT NULL,
  orden INTEGER DEFAULT 0,
  PRIMARY KEY (grupo_id, cap_code)
);
CREATE TABLE IF NOT EXISTS config (
  clave TEXT PRIMARY KEY,
  valor TEXT
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
CREATE INDEX IF NOT EXISTS idx_pagers_codigo ON pagers(codigo);
CREATE INDEX IF NOT EXISTS idx_grupos_codigo ON grupos(codigo);
EOF

# --- database/seed.sql ---
cat > "${APP_DIR}/database/seed.sql" <<'EOF'
INSERT OR IGNORE INTO config (clave, valor) VALUES
 ('mensaje_timeout','5'),
 ('ptt_preactivo','0.5'),
 ('digit_timeout','5'),
 ('response_timeout','20'),
 ('max_grupo_capcodes','20');

INSERT OR IGNORE INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion) VALUES
 ('10','00002020','Juan','Pérez','Guardia Médica',1200,'Médico de guardia'),
 ('11','00002021','María','Gómez','Enfermería',1200,'Enfermera de guardia'),
 ('12','00002022','Carlos','Ruiz','Trauma',1200,'Traumatólogo'),
 ('99','00000099','Sistema','Test','Sistemas',512,'Prueba de sistema');

INSERT OR IGNORE INTO grupos (codigo,nombre,baudios) VALUES
 ('20','Código Azul - Guardia Médica',1200),
 ('21','Emergencias Generales',1200);

INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES
 (1,'00002020',1), (1,'00002021',2),
 (2,'00002020',1), (2,'00002021',2), (2,'00002022',3);
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

def get_config(clave, default="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT valor FROM config WHERE clave=?",(clave,)).fetchone()
        return row["valor"] if row else default

def set_config(clave, valor, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO config(clave,valor) VALUES(?,?) "
                     "ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor",(clave,valor))

def all_config(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return {r["clave"]:r["valor"] for r in conn.execute("SELECT * FROM config")}

# Devuelve (caps, baudios, tipo). caps es "cap" individual o "cap1,cap2,..." para grupo
def resolver_destino(codigo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        row = conn.execute("SELECT cap_code,baudios,tipo FROM pagers WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        if row:
            return (row["cap_code"], row["baudios"], row["tipo"] or "individual")
        grow = conn.execute("SELECT id,baudios FROM grupos WHERE codigo=? AND activo=1",(codigo,)).fetchone()
        if grow:
            members = conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(grow["id"],)).fetchall()
            caps = ",".join(m["cap_code"] for m in members)
            return (caps, grow["baudios"], "grupo")
        return None

def registrar_bitacora(interno, codigo, cap_code, mensaje, baudios, estado, obs="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO bitacora (interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones) VALUES (?,?,?,?,?,?,?)",
                     (interno,codigo,cap_code,mensaje,baudios,estado,obs))

def listar_pagers(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]

def crear_pager(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion,activo) VALUES (?,?,?,?,?,?,?,1)",
                     (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
                      data.get("area"),data.get("baudios",1200),data.get("descripcion")))
        return conn.execute("SELECT * FROM pagers WHERE codigo=?",(data["codigo"],)).fetchone()["id"]

def actualizar_pager(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET codigo=?,cap_code=?,nombre=?,apellido=?,area=?,baudios=?,descripcion=? WHERE id=?",
                     (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
                      data.get("area"),data.get("baudios",1200),data.get("descripcion"),pid))

def borrar_pager(pid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM pagers WHERE id=?",(pid,))

def listar_grupos(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall()
        out=[]
        for g in rows:
            miembros=[m["cap_code"] for m in conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(g["id"],)).fetchall()]
            out.append({**dict(g),"miembros":miembros})
        return out

def crear_grupo(data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1)",
                     (data["codigo"],data.get("nombre"),data.get("baudios",1200)))
        gid=cur.lastrowid
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))
        return gid

def actualizar_grupo(gid, data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        conn.execute("UPDATE grupos SET codigo=?,nombre=?,baudios=? WHERE id=?",
                     (data["codigo"],data.get("nombre"),data.get("baudios",1200),gid))
        conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?",(gid,))
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))

def borrar_grupo(gid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM grupos WHERE id=?",(gid,))

def bitacora_reciente(limit=50, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM bitacora ORDER BY id DESC LIMIT ?",(limit,))]

def bitacora_filtrada(filtros, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v,list) else v
    where=[]; args=[]
    if filtros.get("fecha_desde"):
        where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"):
        where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k,col in (("codigo","codigo"),("cap_code","cap_code"),("estado","estado"),("interno","interno_origen")):
        v=filtros.get(k)
        v=val(v) if v else ""
        if v: where.append(f"{col} LIKE ?"); args.append(f"%{v}%")
    sql="SELECT * FROM bitacora"
    if where: sql+=" WHERE "+" AND ".join(where)
    sql+=" ORDER BY id DESC LIMIT 5000"
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute(sql,args)]

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    import subprocess, sys
    if not codigo or not mensaje: return {"status":"error","detalle":"falta código o mensaje"}
    handler="/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler="/opt/pocsag-server/agi/pocsag_handler.py"
    rc=subprocess.run([sys.executable,handler,origen,codigo,mensaje],capture_output=True,text=True)
    if rc.returncode==0: return {"status":"enviado"}
    return {"status":"error","detalle":rc.stderr.strip() or "falló el envío"}

if __name__ == "__main__":
    import sys
    if len(sys.argv)>1 and sys.argv[1]=="init": init_db(); print("Base de datos inicializada.")
EOF
mkx "${APP_DIR}/database/db_manager.py"

# --- asterisk/extensions_pocsag.conf ---
cat > "${APP_DIR}/asterisk/extensions_pocsag.conf" <<'EOF'
[pocsag-incoming]
exten => 2184,1,NoOp(=== Paginación hospitalaria POCSAG ===)
 same => n,Answer()
 same => n,Set(TIMEOUT(digit)=5)
 same => n,Set(TIMEOUT(response)=30)
 same => n(loop),Playback(despues-del-tono-marque-codigo)
 same => n,Playback(beep)
 same => n,Read(CODE,,8,,3,5)
 same => n,GotoIf($["${CODE}" = ""]?fin)
 same => n,AGI(pocsag_check.py,${CODE})
 same => n,GotoIf($["${POCSAG_VALID}" = "1"]?pedir_mensaje:codigo_invalido)
 same => n(codigo_invalido),Playback(codigo-inexistente)
 same => n,Playback(marque-otro-codigo)
 same => n,Wait(0.5)
 same => n,Goto(loop)
 same => n(pedir_mensaje),Playback(despues-de-la-senal-su-mensaje)
 same => n,Playback(beep)
 same => n,Read(MESSAGE,,16,,3,${POCSAG_MSJ_TIMEOUT})
 same => n,GotoIf($["${MESSAGE}" = ""]?mensaje_vacio:enviar)
 same => n(enviar),AGI(pocsag_handler.py,${CALLERID(num)},${CODE},${MESSAGE})
 same => n,GotoIf($["${AGISTATUS}" = "SUCCESS"]?ok:fail)
 same => n(ok),Playback(confirmado)
 same => n,Hangup()
 same => n(fail),Playback(error-envio)
 same => n,Hangup()
 same => n(mensaje_vacio),Playback(mensaje-vacio)
 same => n,Goto(pedir_mensaje)
 same => n(fin),Playback(mensaje-vacio)
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

# --- agi/pocsag_check.py ---
cat > "${APP_DIR}/agi/pocsag_check.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, get_config

def main():
    codigo = sys.argv[1] if len(sys.argv)>1 else ""
    dest = resolver_destino(codigo)
    if not dest:
        sys.stdout.write("SET VARIABLE POCSAG_VALID 0\n"); sys.stdout.flush(); return
    caps, baud, tipo = dest
    timeout = get_config("mensaje_timeout", "5")
    sys.stdout.write("SET VARIABLE POCSAG_VALID 1\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_CAPS {caps}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_BAUD {baud}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_TIPO {tipo}\n")
    sys.stdout.write(f"SET VARIABLE POCSAG_MSJ_TIMEOUT {timeout}\n")
    sys.stdout.flush()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_check.py"

# --- agi/pocsag_handler.py ---
cat > "${APP_DIR}/agi/pocsag_handler.py" <<'EOF'
#!/usr/bin/env python3
import sys, os, subprocess, traceback, time
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import resolver_destino, registrar_bitacora, get_config

AUDIO_DIR = "/opt/pocsag-server/audio"
PTT_ON = "/opt/pocsag-server/scripts/ptt_on.sh"
PTT_OFF = "/opt/pocsag-server/scripts/ptt_off.sh"
ENCODER = "/opt/pocsag-server/encoder/pocsag_gen.py"

def log(msg):
    os.makedirs("/opt/pocsag-server/logs",exist_ok=True)
    with open("/opt/pocsag-server/logs/pocsag.log","a") as f: f.write(f"[AGI] {msg}\n")

def fail():
    subprocess.run([PTT_OFF], check=False)
    sys.stdout.write("SET VARIABLE AGISTATUS FAILURE\n"); sys.stdout.flush(); sys.exit(0)

def main():
    try:
        interno = sys.argv[1] if len(sys.argv)>1 else "unknown"
        codigo = sys.argv[2] if len(sys.argv)>2 else ""
        mensaje = sys.argv[3] if len(sys.argv)>3 else ""
        if not codigo: fail()
        dest = resolver_destino(codigo)
        if not dest: log(f"Código no encontrado: {codigo}"); fail()
        caps, baudios, tipo = dest
        cap_list = [c.strip() for c in caps.split(",") if c.strip()]
        ptt_preactivo = float(get_config("ptt_preactivo","0.5"))
        os.makedirs(AUDIO_DIR, exist_ok=True)
        wavs = []
        for cap in cap_list:
            wav = os.path.join(AUDIO_DIR, f"out_{cap}.wav")
            rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav], capture_output=True, text=True)
            if rc.returncode != 0:
                log(f"Encoder falló para {cap}: {rc.stderr}")
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "error", "encoder")
                fail()
            wavs.append(wav)
        subprocess.run([PTT_ON], check=True)
        time.sleep(ptt_preactivo)
        for wav in wavs:
            subprocess.run(["aplay","-q",wav], check=True)
        subprocess.run([PTT_OFF], check=True)
        for cap in cap_list:
            registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado")
        sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
        log(f"Envío OK interno={interno} codigo={codigo} caps={caps} tipo={tipo} msg={mensaje}")
    except Exception as e:
        log(f"Excepción: {e}\n{traceback.format_exc()}"); fail()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_handler.py"

# --- encoder/pocsag_gen.py ---
cat > "${APP_DIR}/encoder/pocsag_gen.py" <<'EOF'
#!/usr/bin/env python3
import sys
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
check asterisk; check pocsag-api 2>/dev/null||true
command -v aplay>/dev/null&&echo "[OK]   aplay"||{ echo "[FAIL] aplay"; ok=0; }
command -v sqlite3>/dev/null&&echo "[OK]   sqlite3"||{ echo "[FAIL] sqlite3"; ok=0; }
command -v python3>/dev/null&&echo "[OK]   python3"||{ echo "[FAIL] python3"; ok=0; }
python3 -c "import pocsag" 2>/dev/null&&echo "[OK]   python-pocsag"||echo "[WARN] python-pocsag"
[[ $ok -eq 1 ]]&&echo "Sistema POCSAG: SALUDABLE"||echo "Sistema POCSAG: REVISAR"
exit $((1-ok))
EOF
mkx "${APP_DIR}/scripts/healthcheck.sh"

# --- services/pocsag-api.service ---
cat > "${APP_DIR}/services/pocsag-api.service" <<'EOF'
[Unit]
Description=API y panel web del sistema POCSAG
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
import os, sys, json, csv, io, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import (listar_pagers, crear_pager, actualizar_pager, borrar_pager,
    listar_grupos, crear_grupo, actualizar_grupo, borrar_grupo,
    all_config, set_config, bitacora_reciente, bitacora_filtrada, enviar_mensaje)

HOST=os.environ.get("POCSAG_API_HOST","0.0.0.0")
PORT=int(os.environ.get("POCSAG_API_PORT","8080"))
FRONT="/opt/pocsag-server/frontend"

def jr(h,d,c=200):
    b=json.dumps(d,ensure_ascii=False).encode()
    h.send_response(c); h.send_header("Content-Type","application/json; charset=utf-8")
    h.send_header("Access-Control-Allow-Origin","*")
    h.send_header("Content-Length",str(len(b))); h.end_headers(); h.wfile.write(b)

def read_body(h):
    ln=int(h.headers.get("Content-Length",0)); return json.loads(h.rfile.read(ln) or b"{}")

AST_BIN="asterisk"
SAFE_CMDS={"status":"core show status","version":"core show version","peers":"pjsip show endpoints",
           "channels":"core show channels","uptime":"core show uptime","dialplan":"dialplan show"}
def ast_run(cmd):
    try:
        r=subprocess.run([AST_BIN,"-rx",cmd],capture_output=True,text=True,timeout=10)
        return (r.stdout or "")+(r.stderr or "")
    except Exception as e:
        return f"Error: {e}"

class H(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type"); self.end_headers()
    def do_GET(self):
        u=urlparse(self.path); p=u.path; q=parse_qs(u.query)
        if p=="/api/pagers": return jr(self,listar_pagers())
        if p=="/api/grupos": return jr(self,listar_grupos())
        if p=="/api/config": return jr(self,all_config())
        if p=="/api/health": return jr(self,{"status":"ok"})
        if p=="/api/bitacora":
            return jr(self,bitacora_filtrada(q) if q else bitacora_reciente(50))
        if p=="/api/bitacora/export":
            rows=bitacora_filtrada(q) if q else bitacora_reciente(10000)
            out=io.StringIO(); out.write('\ufeff')
            w=csv.writer(out); w.writerow(["Fecha/Hora","Interno","Codigo","CapCode","Mensaje","Baudios","Estado","Observaciones"])
            for r in rows:
                w.writerow([r.get("fecha_hora"),r.get("interno_origen"),r.get("codigo"),r.get("cap_code"),
                            r.get("mensaje"),r.get("baudios"),r.get("estado"),r.get("observaciones")])
            data=out.getvalue().encode("utf-8")
            self.send_response(200); self.send_header("Content-Type","text/csv; charset=utf-8")
            self.send_header("Content-Disposition",'attachment; filename="bitacora_pocsag.csv"')
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data); return
        if p=="/api/asterisk":
            sub=q.get("cmd",["status"])[0]; acmd=SAFE_CMDS.get(sub)
            if not acmd: return jr(self,{"error":"comando no permitido"},400)
            return jr(self,{"cmd":sub,"salida":ast_run(acmd)})
        if p in ("/","/index.html"):
            f=os.path.join(FRONT,"index.html")
            if os.path.exists(f):
                self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
                with open(f,"rb") as fh: self.wfile.write(fh.read()); return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        p=self.path; data=read_body(self)
        try:
            if p=="/api/pagers": return jr(self,{"id":crear_pager(data)})
            if p=="/api/grupos": return jr(self,{"id":crear_grupo(data)})
            if p=="/api/enviar":
                return jr(self, enviar_mensaje(data.get("codigo",""), data.get("mensaje",""), data.get("origen","web")))
            if p=="/api/asterisk/reload":
                return jr(self,{"salida":ast_run("dialplan reload")+"\n"+ast_run("pjsip reload")})
            if p=="/api/asterisk/restart":
                return jr(self,{"salida":ast_run("core restart now")})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_PUT(self):
        parts=self.path.split("/"); data=read_body(self)
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3: actualizar_pager(int(parts[3]),data); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3: actualizar_grupo(int(parts[3]),data); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="config":
                for k,v in data.items(): set_config(k,str(v))
                return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_DELETE(self):
        parts=self.path.split("/")
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3: borrar_pager(int(parts[3])); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3: borrar_grupo(int(parts[3])); return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
EOF
mkx "${APP_DIR}/backend/app.py"

# --- frontend/index.html ---
cat > "${APP_DIR}/frontend/index.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG - Paginación Hospitalaria</title>
<style>
body{font-family:system-ui;margin:0;background:#0f172a;color:#e2e8f0}
header{background:#1e293b;padding:1rem 2rem;border-bottom:1px solid #334155;display:flex;justify-content:space-between;align-items:center}
h1{margin:0;font-size:1.25rem}
nav{display:flex;gap:.3rem;flex-wrap:wrap;padding:.8rem 2rem;background:#1e293b;border-bottom:1px solid #334155}
nav button{background:#0f172a;border:1px solid #334155;color:#94a3b8;border-radius:.3rem;padding:.4rem .9rem;cursor:pointer;font-size:.85rem}
nav button.active{background:#0ea5e9;color:#fff;border-color:#0ea5e9}
main{padding:1.5rem 2rem;display:grid;gap:1.2rem;max-width:1200px;margin:auto}
.tab{display:none}.tab.active{display:block}
.card{background:#1e293b;border:1px solid #334155;border-radius:.5rem;padding:1.2rem;margin-bottom:1rem}
.card h2{margin:0 0 .8rem;font-size:1rem;color:#38bdf8;display:flex;justify-content:space-between;align-items:center}
table{width:100%;border-collapse:collapse;font-size:.83rem}th,td{text-align:left;padding:.4rem;border-bottom:1px solid #334155}th{color:#94a3b8}
input,select,textarea{background:#0f172a;border:1px solid #334155;color:#e2e8f0;border-radius:.3rem;padding:.35rem .5rem;font-size:.85rem;width:100%;box-sizing:border-box}
button{cursor:pointer;border:none;border-radius:.3rem;padding:.4rem .8rem;font-size:.85rem;font-weight:600}
.btn{background:#0ea5e9;color:#fff}.btn:hover{background:#0284c7}
.btn-del{background:#dc2626;color:#fff}.btn-del:hover{background:#b91c1c}
.btn-add{background:#16a34a;color:#fff}.btn-add:hover{background:#15803d}
.btn-warn{background:#d97706;color:#fff}.btn-warn:hover{background:#b45309}
.row{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:.5rem}.row>*{flex:1;min-width:90px}
.badge{padding:.15rem .5rem;border-radius:9999px;font-size:.7rem;background:#334155}
.ok{background:#064e3b;color:#6ee7b7}.err{background:#7f1d1d;color:#fca5a5}
pre{background:#0f172a;border:1px solid #334155;border-radius:.3rem;padding:.8rem;overflow:auto;max-height:320px;font-size:.78rem;white-space:pre-wrap}
label{display:block;font-size:.75rem;color:#94a3b8;margin:.3rem 0 .15rem}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:10}
.modal.open{display:flex}.modal .card{width:92%;max-width:520px;margin:0}
.filters{display:flex;gap:.5rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:.8rem}.filters>*{flex:1;min-width:120px}
.filters .btn,.filters .btn-add{flex:0 0 auto}
</style></head>
<body>
<header><h1>🏥 Paginación POCSAG</h1><span id="h" class="badge">…</span></header>
<nav>
<button class="active" onclick="tab('enviar',event)">Enviar</button>
<button onclick="tab('pagers',event)">Pagers</button>
<button onclick="tab('grupos',event)">Grupos</button>
<button onclick="tab('asterisk',event)">Asterisk</button>
<button onclick="tab('bitacora',event)">Bitácora</button>
<button onclick="tab('config',event)">Parámetros</button>
</nav>
<main>
<div class="tab active" id="t-enviar"><div class="card"><h2>Enviar mensaje a pager/grupo</h2>
<div class="row"><div><label>Código</label><select id="e_cod"></select></div><div><label>Mensaje</label><input id="e_msg" placeholder="Texto alfanumérico"></div></div>
<button class="btn" onclick="enviar()">Enviar a pager</button>
<div id="e_res" style="margin-top:.6rem"></div>
</div></div>
<div class="tab" id="t-pagers"><div class="card"><h2>Pagers individuales <button class="btn-add" onclick="openPager()">+ Nuevo pager</button></h2>
<table><thead><tr><th>Código</th><th>CapCode</th><th>Nombre</th><th>Apellido</th><th>Área</th><th>Baud</th><th></th></tr></thead><tbody id="cod"></tbody></table></div></div>
<div class="tab" id="t-grupos"><div class="card"><h2>Grupos (hasta 20 capcodes) <button class="btn-add" onclick="openGrupo()">+ Nuevo grupo</button></h2>
<table><thead><tr><th>Código</th><th>Nombre</th><th>CapCodes</th><th>Baud</th><th></th></tr></thead><tbody id="grp"></tbody></table></div></div>
<div class="tab" id="t-asterisk"><div class="card"><h2>Gestión de Asterisk</h2>
<div style="display:flex;gap:.4rem;flex-wrap:wrap;margin-bottom:.8rem">
<button class="btn" onclick="ast('status')">Estado</button>
<button class="btn" onclick="ast('peers')">Endpoints</button>
<button class="btn" onclick="ast('channels')">Canales</button>
<button class="btn" onclick="ast('uptime')">Uptime</button>
<button class="btn-warn" onclick="astReload()">Recargar config</button>
<button class="btn-del" onclick="astRestart()">Reiniciar Asterisk</button>
</div>
<pre id="ast_out">—</pre>
</div></div>
<div class="tab" id="t-bitacora"><div class="card"><h2>Bitácora de envíos</h2>
<div class="filters">
<div><label>Desde</label><input id="b_desde" type="date"></div>
<div><label>Hasta</label><input id="b_hasta" type="date"></div>
<div><label>Código</label><input id="b_codigo" placeholder="ej 10"></div>
<div><label>Interno</label><input id="b_interno" placeholder="ej 101"></div>
<div><label>Estado</label><select id="b_estado"><option value="">Todos</option><option>enviado</option><option>error</option></select></div>
<button class="btn" onclick="loadBit()">Filtrar</button>
<button class="btn-add" onclick="exportBit()">Exportar Excel</button>
</div>
<table><thead><tr><th>Fecha</th><th>Interno</th><th>Código</th><th>Cap</th><th>Msg</th><th>Estado</th></tr></thead><tbody id="bit"></tbody></table>
</div></div>
<div class="tab" id="t-config"><div class="card"><h2>Parámetros del sistema</h2>
<div class="row"><div><label>Timeout mensaje (seg)</label><input id="c_mensaje_timeout" type="number" step="1"></div>
<div><label>PTT pre-activo (seg)</label><input id="c_ptt_preactivo" type="number" step="0.1"></div>
<div><label>Timeout dígitos (seg)</label><input id="c_digit_timeout" type="number" step="1"></div>
<div><label>Timeout respuesta (seg)</label><input id="c_response_timeout" type="number" step="1"></div></div>
<button class="btn" onclick="saveConfig()">Guardar parámetros</button></div></div>
</main>
<div class="modal" id="mPager"><div class="card"><h2 id="mPagerTitle">Pager</h2>
<label>Código (marcado por DTMF)</label><input id="p_codigo">
<label>CapCode</label><input id="p_cap">
<div class="row"><div><label>Nombre</label><input id="p_nombre"></div><div><label>Apellido</label><input id="p_apellido"></div></div>
<label>Área</label><input id="p_area">
<div class="row"><div><label>Baudios</label><input id="p_baud" type="number" value="1200"></div><div><label>Descripción</label><input id="p_desc"></div></div>
<div style="display:flex;gap:.5rem;margin-top:.8rem"><button class="btn" onclick="savePager()">Guardar</button><button class="btn-del" onclick="closeModal('mPager')">Cancelar</button></div></div></div>
<div class="modal" id="mGrupo"><div class="card"><h2 id="mGrupoTitle">Grupo</h2>
<label>Código (marcado por DTMF)</label><input id="g_codigo">
<label>Nombre</label><input id="g_nombre">
<label>CapCodes (uno por línea, máx 20)</label><textarea id="g_miembros" rows="6"></textarea>
<div class="row" style="margin-top:.4rem"><div><label>Baudios</label><input id="g_baud" type="number" value="1200"></div></div>
<div style="display:flex;gap:.5rem;margin-top:.8rem"><button class="btn" onclick="saveGrupo()">Guardar</button><button class="btn-del" onclick="closeModal('mGrupo')">Cancelar</button></div></div></div>
<script>
const g=u=>fetch(u).then(r=>r.json());
const badge=e=>e==='enviado'?`<span class="badge ok">${e}</span>`:`<span class="badge err">${e||'-'}</span>`;
let editPager=null,editGrupo=null;
function tab(id,e){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('nav button').forEach(b=>b.classList.remove('active'));document.getElementById('t-'+id).classList.add('active');e.target.classList.add('active');if(id==='bitacora')loadBit();}
function openModal(id){document.getElementById(id).classList.add('open');}
function closeModal(id){document.getElementById(id).classList.remove('open');}
async function loadPagers(){const c=await g('/api/pagers');document.getElementById('cod').innerHTML=c.map(x=>`<tr><td>${x.codigo}</td><td>${x.cap_code}</td><td>${x.nombre||''}</td><td>${x.apellido||''}</td><td>${x.area||''}</td><td>${x.baudios}</td><td><button class="btn" onclick="openPager(${x.id})">✎</button> <button class="btn-del" onclick="delPager(${x.id})">✕</button></td></tr>`).join('');}
async function loadCodigos(){const c=await g('/api/pagers');const gr=await g('/api/grupos');const s=document.getElementById('e_cod');s.innerHTML='';c.forEach(x=>{const o=document.createElement('option');o.value=x.codigo;o.textContent=`${x.codigo} — ${x.nombre||''} ${x.apellido||''} (${x.area||x.cap_code})`;s.appendChild(o);});gr.forEach(x=>{const o=document.createElement('option');o.value=x.codigo;o.textContent=`${x.codigo} — GRUPO: ${x.nombre||''} (${(x.miembros||[]).length} pagers)`;s.appendChild(o);});}
async function loadGrupos(){const gr=await g('/api/grupos');document.getElementById('grp').innerHTML=gr.map(x=>`<tr><td>${x.codigo}</td><td>${x.nombre||''}</td><td>${(x.miembros||[]).join(', ')}</td><td>${x.baudios}</td><td><button class="btn" onclick="openGrupo(${x.id})">✎</button> <button class="btn-del" onclick="delGrupo(${x.id})">✕</button></td></tr>`).join('');}
async function enviar(){const codigo=document.getElementById('e_cod').value,mensaje=document.getElementById('e_msg').value.trim();if(!codigo||!mensaje){document.getElementById('e_res').innerHTML='<span class="badge err">Falta código o mensaje</span>';return;}
const r=await fetch('/api/enviar',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({codigo,mensaje,origen:'web'})}).then(r=>r.json());
document.getElementById('e_res').innerHTML=r.status==='enviado'?'<span class="badge ok">Enviado correctamente</span>':`<span class="badge err">Error: ${r.detalle||''}</span>`;loadBit();}
async function openPager(id){editPager=id||null;const p=await g('/api/pagers');const x=id?p.find(i=>i.id===id):null;
['codigo','cap','nombre','apellido','area','desc'].forEach(f=>document.getElementById('p_'+f).value=x?x[f==='cap'?'cap_code':f]||'':'');
document.getElementById('p_baud').value=x?x.baudios:1200;document.getElementById('mPagerTitle').textContent=id?'Editar pager':'Nuevo pager';openModal('mPager');}
async function savePager(){const d={codigo:document.getElementById('p_codigo').value,cap_code:document.getElementById('p_cap').value,nombre:document.getElementById('p_nombre').value,apellido:document.getElementById('p_apellido').value,area:document.getElementById('p_area').value,baudios:+document.getElementById('p_baud').value,descripcion:document.getElementById('p_desc').value};
if(editPager)await fetch('/api/pagers/'+editPager,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});else await fetch('/api/pagers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});closeModal('mPager');loadPagers();loadCodigos();}
async function delPager(id){if(confirm('¿Eliminar pager?')){await fetch('/api/pagers/'+id,{method:'DELETE'});loadPagers();loadCodigos();}}
async function openGrupo(id){editGrupo=id||null;const gr=await g('/api/grupos');const x=id?gr.find(i=>i.id===id):null;
document.getElementById('g_codigo').value=x?x.codigo:'';document.getElementById('g_nombre').value=x?x.nombre||'':'';document.getElementById('g_miembros').value=x?(x.miembros||[]).join('\n'):'';document.getElementById('g_baud').value=x?x.baudios:1200;document.getElementById('mGrupoTitle').textContent=id?'Editar grupo':'Nuevo grupo';openModal('mGrupo');}
async function saveGrupo(){const d={codigo:document.getElementById('g_codigo').value,nombre:document.getElementById('g_nombre').value,baudios:+document.getElementById('g_baud').value,miembros:document.getElementById('g_miembros').value.split('\n').map(s=>s.trim()).filter(Boolean).slice(0,20)};
if(editGrupo)await fetch('/api/grupos/'+editGrupo,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});else await fetch('/api/grupos',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});closeModal('mGrupo');loadGrupos();loadCodigos();}
async function delGrupo(id){if(confirm('¿Eliminar grupo?')){await fetch('/api/grupos/'+id,{method:'DELETE'});loadGrupos();loadCodigos();}}
async function loadConfig(){const cfg=await g('/api/config');['mensaje_timeout','ptt_preactivo','digit_timeout','response_timeout'].forEach(k=>{const el=document.getElementById('c_'+k);if(el&&cfg[k]!=null)el.value=cfg[k];});}
async function saveConfig(){const d={mensaje_timeout:document.getElementById('c_mensaje_timeout').value,ptt_preactivo:document.getElementById('c_ptt_preactivo').value,digit_timeout:document.getElementById('c_digit_timeout').value,response_timeout:document.getElementById('c_response_timeout').value};await fetch('/api/config',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)});alert('Parámetros guardados');loadConfig();}
function bitQuery(){const p=new URLSearchParams();const d=document.getElementById('b_desde').value,h=document.getElementById('b_hasta').value,c=document.getElementById('b_codigo').value,i=document.getElementById('b_interno').value,e=document.getElementById('b_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p.toString();}
async function loadBit(){const qs=bitQuery();const b=await g('/api/bitacora'+(qs?('?'+qs):''));document.getElementById('bit').innerHTML=b.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${badge(x.estado)}</td></tr>`).join('');}
function exportBit(){const qs=bitQuery();window.open('/api/bitacora/export'+(qs?('?'+qs):''),'_blank');}
async function ast(cmd){const r=await g('/api/asterisk?cmd='+cmd);document.getElementById('ast_out').textContent=r.salida||r.error||'';}
async function astReload(){if(!confirm('¿Recargar configuración de Asterisk?'))return;const r=await fetch('/api/asterisk/reload',{method:'POST'}).then(r=>r.json());document.getElementById('ast_out').textContent=r.salida||'';}
async function astRestart(){if(!confirm('¿Reiniciar Asterisk? Se cortarán llamadas activas.'))return;const r=await fetch('/api/asterisk/restart',{method:'POST'}).then(r=>r.json());document.getElementById('ast_out').textContent=r.salida||'';}
async function health(){try{const h=await g('/api/health');document.getElementById('h').textContent=h.status==='ok'?'en línea':'caído';}catch(e){document.getElementById('h').textContent='caído';}}
(async()=>{health();loadPagers();loadGrupos();loadCodigos();loadConfig();loadBit();setInterval(health,10000);})();
</script></body></html>
EOF

# --- bin/uninstall.sh ---
cat > "${APP_DIR}/bin/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP="/opt/pocsag-server"; PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1
[[ $EUID -ne 0 ]] && { echo "root/sudo"; exit 1; }
systemctl disable --now pocsag-api 2>/dev/null||true
systemctl stop asterisk 2>/dev/null||true
rm -f /etc/systemd/system/pocsag-api.service
systemctl daemon-reload
rm -f /etc/asterisk/extensions_pocsag.conf /etc/asterisk/pjsip_pocsag.conf
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py /var/lib/asterisk/agi-bin/pocsag_check.py
rm -f /etc/logrotate.d/pocsag
if [[ $PURGE -eq 1 ]]; then rm -rf "$APP"; rm -f /var/log/pocsag-install.log
else cp "$APP/database/pocsag.db" /tmp/pocsag-backup.db 2>/dev/null||true; rm -rf "$APP"; fi
echo "Desinstalación completa (Asterisk y deps NO se quitan)."
EOF
mkx "${APP_DIR}/bin/uninstall.sh"

chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}"

# ============================ 4. BASE DE DATOS ==============================
echo "==> 3/9 Inicializando base de datos..."
python3 "${APP_DIR}/database/db_manager.py" init
chmod 640 "${APP_DIR}/database/pocsag.db" 2>/dev/null || true

# ============================ 5. ASTERISK ==================================
echo "==> 4/9 Configurando Asterisk..."
AST_ETC="/etc/asterisk"
cp "${APP_DIR}/asterisk/extensions_pocsag.conf" "${AST_ETC}/"
cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${AST_ETC}/"
cp "${APP_DIR}/asterisk/modules.conf" "${AST_ETC}/"
grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"
grep -q 'pjsip_pocsag.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_pocsag.conf' >> "${AST_ETC}/pjsip.conf"

# ============================ 6. AGI ======================================
echo "==> 5/9 Instalando AGI..."
mkdir -p /var/lib/asterisk/agi-bin
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
mkx /var/lib/asterisk/agi-bin/pocsag_handler.py
mkx /var/lib/asterisk/agi-bin/pocsag_check.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin

# ============================ 7. LOCUCIONES ==============================
echo "==> 6/9 Generando locuciones IVR..."
gen(){ local out="${APP_DIR}/audio/$1.gsm"; [[ -f "$out" ]] && return
  espeak -v es -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null || warn "No se pudo generar $1"
  rm -f "${out%.gsm}.wav"; }
gen despues-del-tono-marque-codigo "Después del tono marque el número de código"
gen despues-de-la-senal-su-mensaje "Después de la señal marque su mensaje"
gen codigo-inexistente "Código inexistente"
gen marque-otro-codigo "Por favor marque otro código"
gen mensaje-vacio "Mensaje vacío"
gen confirmado "Mensaje enviado"
gen error-envio "Error de envío"
sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null || warn "beep no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds/ 2>/dev/null || true

# ============================ 8. SYSTEMD + LOGROTATE =====================
echo "==> 7/9 Servicios systemd + logrotate..."
cp "${APP_DIR}/services/"*.service /etc/systemd/system/
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
systemctl daemon-reload
systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
systemctl enable --now pocsag-api 2>/dev/null || warn "API no pudo activarse"

# ============================ 9. RECARGA + CHEQUEO =======================
echo "==> 8/9 Recargando Asterisk y chequeando..."
asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
asterisk -rx "pjsip reload" 2>/dev/null || true
bash "${APP_DIR}/scripts/healthcheck.sh" || warn "Healthcheck reportó problemas"

echo "==> 9/9 Listo."
echo "--------------------------------------------"
log "Instalación completada en ${APP_DIR}"
cat <<'EOF'

PROXIMOS PASOS:
  1. Editar /opt/pocsag-server/scripts/ptt_on.sh y ptt_off.sh (pin GPIO/relé real).
  2. Cambiar el password en /etc/asterisk/pjsip_pocsag.conf (interno 2184).
  3. Calibrar nivel de audio y desviación del TX (±4.5 kHz POCSAG).
  4. Registrar un SIP en contexto pocsag-incoming y marcar 2184 para probar.
  5. Panel web (gestionar pagers/grupos/parámetros):  http://<servidor>:8080/
  6. Bitácora: sqlite3 /opt/pocsag-server/database/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

Desinstalar: sudo /opt/pocsag-server/bin/uninstall.sh
EOF