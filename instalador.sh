#!/usr/bin/env bash
# ============================================================================
# instalador.sh  -  Sistema de Paginacion Hospitalaria POCSAG sobre VoIP
# ============================================================================
# Objetivo: PBX con FreePBX 17 + sistema POCSAG integrado, en Ubuntu 22.04.
# Uso:    sudo bash instalador.sh
# Forzar instalacion de FreePBX 17 (best-effort): sudo INSTALL_FREEPBX=1 bash instalador.sh
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
[[ $EUID -ne 0 ]] && { err "Ejecuta como root o con sudo."; exit 1; }
grep -q 'Ubuntu 22.04' /etc/os-release 2>/dev/null || warn "No se detecto Ubuntu 22.04. Continuando bajo tu responsabilidad."

mkdir -p "${LOG_FILE%/*}"
exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "==> Instalando sistema POCSAG + FreePBX en ${APP_DIR}"

# ============================ 1. DEPENDENCIAS ================================
echo "==> 1/10 Dependencias base..."
apt-get update -y
apt-get install -y sqlite3 python3 python3-pip alsa-utils sox git \
  libgpiod2 gpiod curl ca-certificates logrotate espeak zip \
  python3-dev build-essential libffi-dev wget
# Codificador POCSAG: implementacion pura en Python (sin paquetes externos, ver encoder/pocsag_gen.py)
# openpyxl para importar codigos desde planillas Excel (.xlsx)
pip3 install --quiet --break-system-packages openpyxl 2>/dev/null || warn "openpyxl no instalado (importacion Excel solo admitira CSV)"

# ============================ 2. ASTERISK (motor) ============================
echo "==> 2/10 Motor Asterisk..."
if ! command -v asterisk >/dev/null 2>&1; then
  apt-get install -y asterisk || { err "No se pudo instalar Asterisk."; exit 1; }
fi
AST_ETC="/etc/asterisk"
mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

# ============================ 3. FREEPBX (opcional) ==========================
FREEPBX=0
instalar_freepbx(){
  echo "==> Instalando FreePBX 17 (puede tardar varios minutos)..."
  apt-get install -y mariadb-server apache2 libapache2-mod-php8.1 \
    php8.1 php8.1-cli php8.1-mysql php8.1-gd php8.1-mbstring php8.1-curl \
    php8.1-xml php8.1-zip php8.1-intl php8.1-bcmath php8.1-sqlite3 \
    php8.1-soap php8.1-ldap php8.1-imap php-pear nodejs \
    || { warn "No se pudieron instalar dependencias de FreePBX"; return 1; }
  systemctl enable --now mariadb 2>/dev/null || true
  systemctl enable --now apache2 2>/dev/null || true
  sed -i 's/^\(User\|Group\).*/\1 asterisk/' /etc/apache2/apache2.conf 2>/dev/null || true
  sed -i 's/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf 2>/dev/null || true
  a2enmod rewrite 2>/dev/null || true
  systemctl restart apache2 2>/dev/null || true
  cd /tmp
  rm -rf freepbx freepbx-17.0-latest.tgz
  if ! wget -q "http://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz"; then
    warn "No se pudo descargar FreePBX"; return 1
  fi
  tar xzf freepbx-17.0-latest.tgz
  cd freepbx
  systemctl start asterisk 2>/dev/null || true
  if ! ./install -n --dbuser root 2>/tmp/freepbx_install.err; then
    warn "FreePBX install fallo (ver /tmp/freepbx_install.err). Se continua con Asterisk nativo."
    return 1
  fi
  fwconsole ma installall 2>/dev/null || true
  fwconsole reload 2>/dev/null || true
  return 0
}
echo "==> 3/10 FreePBX..."
if command -v fwconsole >/dev/null 2>&1; then
  log "FreePBX detectado."; FREEPBX=1
elif [[ "${INSTALL_FREEPBX:-0}" == "1" ]]; then
  if instalar_freepbx; then FREEPBX=1; log "FreePBX instalado."; else warn "FreePBX no disponible. Integrando con Asterisk nativo."; fi
else
  warn "FreePBX no detectado. Se integra con Asterisk nativo."
  warn "Para instalar FreePBX 17: sudo INSTALL_FREEPBX=1 bash instalador.sh  (o sigue los pasos al final)"
fi

# ============================ 4. ESTRUCTURA =================================
echo "==> 4/10 Estructura..."
mkdir -p "${APP_DIR}"/{asterisk,agi,encoder,database,services,scripts,config,backend,frontend,docs,tests,audio,logs,bin}

# ============================ 5. ARCHIVOS ==================================
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
sample_rate   = 38400

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
CREATE TABLE IF NOT EXISTS extensiones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero TEXT UNIQUE NOT NULL,
  password TEXT,
  contexto TEXT DEFAULT 'pocsag-incoming',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
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
CREATE INDEX IF NOT EXISTS idx_bitacora_codigo ON bitacora(codigo);
CREATE INDEX IF NOT EXISTS idx_bitacora_cap ON bitacora(cap_code);
CREATE INDEX IF NOT EXISTS idx_bitacora_estado ON bitacora(estado);
CREATE INDEX IF NOT EXISTS idx_bitacora_interno ON bitacora(interno_origen);
CREATE INDEX IF NOT EXISTS idx_pagers_codigo ON pagers(codigo);
CREATE INDEX IF NOT EXISTS idx_pagers_cap ON pagers(cap_code);
CREATE INDEX IF NOT EXISTS idx_pagers_nombre ON pagers(nombre);
CREATE INDEX IF NOT EXISTS idx_pagers_apellido ON pagers(apellido);
CREATE INDEX IF NOT EXISTS idx_pagers_area ON pagers(area);
CREATE INDEX IF NOT EXISTS idx_grupos_codigo ON grupos(codigo);
CREATE INDEX IF NOT EXISTS idx_extensiones_numero ON extensiones(numero);
EOF

# --- database/seed.sql ---
cat > "${APP_DIR}/database/seed.sql" <<'EOF'
INSERT OR IGNORE INTO config (clave, valor) VALUES
 ('mensaje_timeout','5'),
 ('ptt_preactivo','0.5'),
 ('digit_timeout','5'),
 ('response_timeout','20'),
 ('max_grupo_capcodes','20'),
 ('test_mode','1'),
 ('admin_user','admin'),
 ('admin_pass','admin123');

INSERT OR IGNORE INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion) VALUES
 ('10','00002020','Juan','Perez','Guardia Medica',1200,'Medico de guardia'),
 ('11','00002021','Maria','Gomez','Enfermeria',1200,'Enfermera de guardia'),
 ('12','00002022','Carlos','Ruiz','Trauma',1200,'Traumatologo'),
 ('99','00000099','Sistema','Test','Sistemas',512,'Prueba de sistema');

INSERT OR IGNORE INTO grupos (codigo,nombre,baudios) VALUES
 ('20','Codigo Azul - Guardia Medica',1200),
 ('21','Emergencias Generales',1200);

INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES
 (1,'00002020',1), (1,'00002021',2),
 (2,'00002020',1), (2,'00002021',2), (2,'00002022',3);

INSERT OR IGNORE INTO extensiones (numero,password,contexto,descripcion) VALUES
 ('101','CAMBIAR_PASSWORD_101','pocsag-incoming','Prueba Zoiper'),
 ('2184','CAMBIAR_PASSWORD_2184','pocsag-incoming','Linea entrante POCSAG');
EOF

# --- database/db_manager.py ---
cat > "${APP_DIR}/database/db_manager.py" <<'EOF'
#!/usr/bin/env python3
import sqlite3, os, secrets, time
from contextlib import contextmanager
DEFAULT_DB = "/opt/pocsag-server/database/pocsag.db"
_TOKENS = {}  # token -> epoch de expiracion

@contextmanager
def get_conn(db_path=DEFAULT_DB):
    conn = sqlite3.connect(db_path); conn.row_factory = sqlite3.Row
    try: yield conn; conn.commit()
    finally: conn.close()

def init_db(db_path=DEFAULT_DB):
    base = os.path.dirname(__file__)
    with get_conn(db_path) as conn:
        with open(os.path.join(base,"schema.sql"),encoding="utf-8") as f: conn.executescript(f.read())
        with open(os.path.join(base,"seed.sql"),encoding="utf-8") as f: conn.executescript(f.read())

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
        conn.execute("UPDATE pagers SET codigo=?,cap_code=?,nombre=?,apellido=?,area=?,baudios=?,descripcion=?,activo=? WHERE id=?",
                     (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
                      data.get("area"),data.get("baudios",1200),data.get("descripcion"),
                      int(data.get("activo",1)),pid))

def toggle_pager(pid, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET activo=? WHERE id=?",(int(activo),pid))

def buscar_pagers(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if not q:
            return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]
        like=f"%{q}%"
        return [dict(r) for r in conn.execute(
            "SELECT * FROM pagers WHERE codigo LIKE ? OR cap_code LIKE ? OR nombre LIKE ? OR apellido LIKE ? OR area LIKE ? ORDER BY codigo",
            (like,like,like,like,like))]

def buscar_grupos(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall() if not q else \
               conn.execute("SELECT * FROM grupos WHERE codigo LIKE ? OR nombre LIKE ? ORDER BY codigo",
                            (f"%{q}%",f"%{q}%")).fetchall()
        out=[]
        for g in rows:
            miembros=[m["cap_code"] for m in conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(g["id"],)).fetchall()]
            out.append({**dict(g),"miembros":miembros})
        return out

def importar_pagers(rows, db_path=DEFAULT_DB):
    n=0; errores=0
    with get_conn(db_path) as conn:
        for r in rows:
            try: baud=int(r.get("baudios") or 1200)
            except (ValueError,TypeError): baud=1200
            try:
                conn.execute("INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion,activo) VALUES (?,?,?,?,?,?,?,1) "
                    "ON CONFLICT(codigo) DO UPDATE SET cap_code=excluded.cap_code,nombre=excluded.nombre,"
                    "apellido=excluded.apellido,area=excluded.area,baudios=excluded.baudios,descripcion=excluded.descripcion",
                    (r["codigo"],r["cap_code"],r.get("nombre",""),r.get("apellido",""),r.get("area",""),baud,r.get("descripcion","")))
                n+=1
            except Exception: errores+=1
    return {"importados":n,"errores":errores}

def listar_extensiones(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM extensiones ORDER BY numero")]

def crear_extension(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
            (data["numero"],data.get("password",""),data.get("contexto","pocsag-incoming") or "pocsag-incoming",data.get("descripcion","")))
        return cur.lastrowid

def actualizar_extension(eid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE extensiones SET numero=?,password=?,contexto=?,descripcion=?,activo=? WHERE id=?",
            (data["numero"],data.get("password",""),data.get("contexto","pocsag-incoming") or "pocsag-incoming",
             data.get("descripcion",""),int(data.get("activo",1)),eid))

def borrar_extension(eid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM extensiones WHERE id=?",(eid,))

def generar_pjsip_conf(db_path=DEFAULT_DB):
    exts=listar_extensiones(db_path)
    lines=["[transport-udp]","type=transport","protocol=udp","bind=0.0.0.0:5060",""]
    for e in exts:
        if not e["activo"]: continue
        num=e["numero"]; ctx=e["contexto"] or "pocsag-incoming"
        lines+=[f"[{num}]","type=endpoint",f"context={ctx}","disallow=all","allow=ulaw,alaw",
                "transport=transport-udp",f"auth={num}-auth",f"aors={num}-aor","",
                f"[{num}-auth]","type=auth","auth_type=userpass",f"username={num}",f"password={e['password'] or ''}","",
                f"[{num}-aor]","type=aor","max_contacts=1",""]
    conf="/etc/asterisk/pjsip_pocsag.conf"
    try:
        with open(conf,"w") as f: f.write("\n".join(lines)+"\n")
        return True
    except PermissionError:
        return False

def login_validar(user, passw, db_path=DEFAULT_DB):
    au=get_config("admin_user","admin"); ap=get_config("admin_pass","admin123")
    if user==au and passw==ap:
        tok=secrets.token_hex(16); _TOKENS[tok]=time.time()+86400; return tok
    return None

def verificar_token(tok):
    exp=_TOKENS.get(tok)
    if not exp: return False
    if time.time()>exp: _TOKENS.pop(tok,None); return False
    return True

def cerrar_sesion(tok):
    _TOKENS.pop(tok,None)

def historial(filtros, limit=50, offset=0, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v,list) else v
    where=[]; args=[]
    if filtros.get("fecha_desde"):
        where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"):
        where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k,col in (("codigo","codigo"),("cap_code","cap_code"),("estado","estado"),("interno","interno_origen")):
        v=filtros.get(k); v=val(v) if v else ""
        if v: where.append(f"{col} LIKE ?"); args.append(f"%{v}%")
    wsql=(" WHERE "+" AND ".join(where)) if where else ""
    with get_conn(db_path) as conn:
        total=conn.execute("SELECT COUNT(*) AS c FROM bitacora"+wsql,args).fetchone()["c"]
        rows=[dict(r) for r in conn.execute("SELECT * FROM bitacora"+wsql+" ORDER BY id DESC LIMIT ? OFFSET ?",args+[limit,offset])]
    return {"rows":rows,"total":total,"limit":limit,"offset":offset}

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
    if not codigo or not mensaje: return {"status":"error","detalle":"falta codigo o mensaje"}
    handler="/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler="/opt/pocsag-server/agi/pocsag_handler.py"
    rc=subprocess.run([sys.executable,handler,origen,codigo,mensaje],capture_output=True,text=True)
    if rc.returncode==0: return {"status":"enviado"}
    return {"status":"error","detalle":rc.stderr.strip() or "fallo el envio"}

if __name__ == "__main__":
    import sys
    if len(sys.argv)>1 and sys.argv[1]=="init": init_db(); print("Base de datos inicializada.")
EOF
mkx "${APP_DIR}/database/db_manager.py"

# --- asterisk dialplan (comun) ---
cat > "${APP_DIR}/asterisk/pocsag_ivr.conf" <<'EOF'
[pocsag-incoming]
exten => 2184,1,NoOp(=== Paginacion hospitalaria POCSAG ===)
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

# --- pjsip endpoint 101 (solo modo nativo, para Zoiper) ---
cat > "${APP_DIR}/asterisk/pjsip_pocsag.conf" <<'EOF'
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

[101]
type=endpoint
context=pocsag-incoming
disallow=all
allow=ulaw,alaw
transport=transport-udp
auth=101-auth
aors=101-aor

[101-auth]
type=auth
auth_type=userpass
username=101
password=CAMBIAR_PASSWORD_101

[101-aor]
type=aor
max_contacts=1

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
        if not dest: log(f"Codigo no encontrado: {codigo}"); fail()
        caps, baudios, tipo = dest
        cap_list = [c.strip() for c in caps.split(",") if c.strip()]
        test_mode = get_config("test_mode","1") == "1"
        ptt_preactivo = float(get_config("ptt_preactivo","0.5"))
        os.makedirs(AUDIO_DIR, exist_ok=True)
        if test_mode:
            for cap in cap_list:
                registrar_bitacora(interno, codigo, cap, mensaje, baudios, "enviado", "modo test")
            sys.stdout.write("SET VARIABLE AGISTATUS SUCCESS\n"); sys.stdout.flush()
            log(f"Envio OK (TEST) interno={interno} codigo={codigo} caps={caps} msg={mensaje}")
            return
        wavs = []
        for cap in cap_list:
            wav = os.path.join(AUDIO_DIR, f"out_{cap}.wav")
            rc = subprocess.run([sys.executable, ENCODER, cap, mensaje, str(baudios), wav], capture_output=True, text=True)
            if rc.returncode != 0:
                log(f"Encoder fallo para {cap}: {rc.stderr}")
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
        log(f"Envio OK interno={interno} codigo={codigo} caps={caps} tipo={tipo} msg={mensaje}")
    except Exception as e:
        log(f"Excepcion: {e}\n{traceback.format_exc()}"); fail()

if __name__ == "__main__": main()
EOF
mkx "${APP_DIR}/agi/pocsag_handler.py"

# --- encoder/pocsag_gen.py ---
cat > "${APP_DIR}/encoder/pocsag_gen.py" <<'EOF'
#!/usr/bin/env python3
# Codificador POCSAG con Filtro Gaussiano para Radios VHF/UHF
# Genera WAV mono 16-bit compatible con entradas de audio comerciales (Mic o Data).
# Basado en el algoritmo de faithanalog/pocsag-encoder.
import sys, wave, struct, math

SYNC = 0x7CD215D8
IDLE = 0x7A89C197
FRAME_SIZE = 2
BATCH_SIZE = 16
PREAMBLE_LENGTH = 576
FLAG_MESSAGE = 0x100000
FUNCTION_ALPHANUMERIC = 0x3
CRC_BITS = 10
CRC_GENERATOR = 0b11101101001
TEXT_BITS_PER_WORD = 20
TEXT_BITS_PER_CHAR = 7

def crc(input_msg):
    denominator = CRC_GENERATOR << 20
    msg = input_msg << CRC_BITS
    for column in range(0, 21):
        if (msg >> (30 - column)) & 1:
            msg ^= denominator
        denominator >>= 1
    return msg & 0x3FF

def parity(x):
    p = 0
    for _ in range(32):
        p ^= (x & 1); x >>= 1
    return p

def encode_codeword(msg, is_message=False):
    base = (0x100000 | (msg & 0xFFFFF)) if is_message else (msg & 0xFFFFF)
    full = (base << CRC_BITS) | crc(base)
    return (full << 1) | parity(full)

def address_offset(address):
    return (address & 0x7) * FRAME_SIZE

def encode_transmission(address, message):
    out = []
    for _ in range(PREAMBLE_LENGTH // 32):
        out.append(0xAAAAAAAA)
    start = len(out)
    out.append(SYNC)
    offset = address_offset(address)
    for _ in range(offset):
        out.append(IDLE)
    addr_data = ((address >> 3) << 2) | FUNCTION_ALPHANUMERIC
    out.append(encode_codeword(addr_data, is_message=False))
    cur = 0; nbits = 0; pos = offset + 1
    for c in message:
        for i in range(TEXT_BITS_PER_CHAR):
            cur = (cur << 1) | ((ord(c) >> i) & 1)
            nbits += 1
            if nbits == TEXT_BITS_PER_WORD:
                out.append(encode_codeword(cur, is_message=True))
                cur = 0; nbits = 0; pos += 1
                if pos == BATCH_SIZE:
                    out.append(SYNC); pos = 0
    if nbits > 0:
        cur <<= (TEXT_BITS_PER_WORD - nbits)
        out.append(encode_codeword(cur, is_message=True))
        pos += 1
        if pos == BATCH_SIZE:
            out.append(SYNC); pos = 0
    out.append(IDLE)
    written = len(out) - start
    pad = (BATCH_SIZE + 1) - (written % (BATCH_SIZE + 1))
    for _ in range(pad):
        out.append(IDLE)
    return out

def modulate_gaussian(codewords, baud, sample_rate):
    spb = sample_rate // baud
    raw_bits = []
    for w in codewords:
        for b in range(31, -1, -1):
            raw_bits.append(1 if (w >> b) & 1 else 0)
    total_samples = len(raw_bits) * spb
    samples = [0.0] * total_samples
    for i, bit in enumerate(raw_bits):
        val = -1.0 if bit == 1 else 1.0
        for s in range(spb):
            samples[i * spb + s] = val
    bt = 0.5
    alpha = math.sqrt(2 * math.log(2)) / (bt / baud)
    filter_size = spb * 2 + 1
    mid = filter_size // 2
    kernel = []
    for i in range(filter_size):
        t = (i - mid) / sample_rate
        h = (alpha / math.sqrt(math.pi)) * math.exp(- (alpha * t) ** 2)
        kernel.append(h)
    ksum = sum(kernel)
    kernel = [x / ksum for x in kernel]
    filtered = [0.0] * total_samples
    for i in range(total_samples):
        val = 0.0
        for k in range(filter_size):
            idx = i - (k - mid)
            if 0 <= idx < total_samples:
                val += samples[idx] * kernel[k]
        filtered[i] = val
    out = []
    for s in filtered:
        amp = max(-32768, min(32767, int(s * 24000)))
        out.append(struct.pack('<h', amp))
    return b''.join(out)

def main():
    if len(sys.argv) != 5:
        print("Uso: pocsag_gen.py <cap> <msg> <baud> <out.wav>", file=sys.stderr)
        return 1
    cap, msg, baud, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    if baud not in (512, 1200, 2400):
        baud = 1200
    sample_rate = 38400
    if sample_rate % baud != 0:
        sample_rate = baud * 32
    codewords = encode_transmission(int(cap), msg)
    data = modulate_gaussian(codewords, baud, sample_rate)
    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sample_rate)
        w.writeframes(data)
    print(f"OK: {out_path} ({baud} bps, {sample_rate} Hz, {len(codewords)} cw)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
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
command -v fwconsole >/dev/null && echo "[OK]   FreePBX (fwconsole)" || echo "[INFO] Asterisk nativo"
if asterisk -rx "core show uptime" >/dev/null 2>&1; then echo "[OK]   asterisk"; else echo "[FAIL] asterisk"; ok=0; fi
check pocsag-api 2>/dev/null||true
command -v aplay>/dev/null&&echo "[OK]   aplay"||{ echo "[FAIL] aplay"; ok=0; }
command -v sqlite3>/dev/null&&echo "[OK]   sqlite3"||{ echo "[FAIL] sqlite3"; ok=0; }
command -v python3>/dev/null&&echo "[OK]   python3"||{ echo "[FAIL] python3"; ok=0; }
python3 /opt/pocsag-server/encoder/pocsag_gen.py 123 test 1200 /tmp/_pocsag_test.wav 2>/dev/null && rm -f /tmp/_pocsag_test.wav && echo "[OK]   encoder POCSAG" || echo "[WARN] encoder POCSAG"
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

# --- services/pocsag-monitor.service ---
cat > "${APP_DIR}/services/pocsag-monitor.service" <<'EOF'
[Unit]
Description=Monitor del sistema POCSAG
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'while true; do if ! asterisk -rx "core show uptime" >/dev/null 2>&1; then if command -v fwconsole >/dev/null; then fwconsole start; else systemctl restart asterisk; fi; fi; /opt/pocsag-server/scripts/healthcheck.sh >> /opt/pocsag-server/logs/health.log 2>&1; sleep 30; done'
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --- backend/app.py ---
cat > "${APP_DIR}/backend/app.py" <<'EOF'
#!/usr/bin/env python3
import os, sys, json, csv, io, subprocess, shutil, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import (listar_pagers, buscar_pagers, crear_pager, actualizar_pager, borrar_pager,
    toggle_pager, importar_pagers,
    listar_grupos, buscar_grupos, crear_grupo, actualizar_grupo, borrar_grupo,
    listar_extensiones, crear_extension, actualizar_extension, borrar_extension, generar_pjsip_conf,
    all_config, set_config, historial, enviar_mensaje, login_validar, verificar_token, cerrar_sesion)

HOST=os.environ.get("POCSAG_API_HOST","0.0.0.0")
PORT=int(os.environ.get("POCSAG_API_PORT","8080"))
FRONT="/opt/pocsag-server/frontend"
HAS_FWCONSOLE = shutil.which("fwconsole") is not None

def jr(h,d,c=200):
    b=json.dumps(d,ensure_ascii=False).encode()
    h.send_response(c); h.send_header("Content-Type","application/json; charset=utf-8")
    h.send_header("Access-Control-Allow-Origin","*")
    h.send_header("Content-Length",str(len(b))); h.end_headers(); h.wfile.write(b)

def read_body(h):
    ln=int(h.headers.get("Content-Length",0)); return json.loads(h.rfile.read(ln) or b"{}")

def run_cmd(args, timeout=15):
    try:
        r=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
        return (r.stdout or "")+(r.stderr or "")
    except Exception as e:
        return f"Error: {e}"

def ast_run(cmd): return run_cmd(["asterisk","-rx",cmd])

SAFE_CMDS={"status":"core show status","version":"core show version","peers":"pjsip show endpoints",
           "channels":"core show channels","uptime":"core show uptime","dialplan":"dialplan show"}

def parse_import(body, filename):
    name=(filename or "").lower(); rows=[]
    if name.endswith(".csv"):
        for r in csv.DictReader(io.StringIO(body.decode("utf-8-sig",errors="replace"))): rows.append(r)
    elif name.endswith(".xlsx"):
        try: import openpyxl
        except ImportError: return None,"openpyxl no instalado. Exporte la planilla como CSV."
        tf=tempfile.NamedTemporaryFile(suffix=".xlsx",delete=False); tf.write(body); tf.close()
        try:
            wb=openpyxl.load_workbook(tf.name, read_only=True); ws=wb.active
            data=list(ws.iter_rows(values_only=True))
        finally: os.unlink(tf.name)
        if not data: return [],None
        headers=[str(h or "").strip().lower() for h in data[0]]
        for row in data[1:]:
            rows.append(dict(zip(headers,[("" if c is None else str(c)) for c in row])))
    else:
        return None,"Formato no soportado. Use .xlsx o .csv"
    def pick(r,*keys):
        for k in keys:
            if k in r and str(r[k]).strip()!="": return str(r[k]).strip()
        return ""
    norm=[]
    for r in rows:
        item={"codigo":pick(r,"codigo","code","id"),"cap_code":pick(r,"cap_code","capcode","cap"),
              "nombre":pick(r,"nombre","name"),"apellido":pick(r,"apellido","surname","lastname"),
              "area":pick(r,"area","sector"),"baudios":pick(r,"baudios","baud") or "1200",
              "descripcion":pick(r,"descripcion","description","obs")}
        if item["codigo"] and item["cap_code"]: norm.append(item)
    return norm,None

class H(BaseHTTPRequestHandler):
    def _auth(self):
        a=self.headers.get("Authorization","")
        return verificar_token(a[7:].strip()) if a.startswith("Bearer ") else False
    def _guard(self):
        if not self._auth():
            jr(self,{"error":"no autorizado"},401); return False
        return True
    def serve_file(self, fn, ctype):
        f=os.path.join(FRONT, fn)
        if os.path.exists(f):
            self.send_response(200); self.send_header("Content-Type",ctype); self.end_headers()
            with open(f,"rb") as fh: self.wfile.write(fh.read())
            return True
        self.send_response(404); self.end_headers(); return False
    def do_OPTIONS(self):
        self.send_response(204); self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Content-Type,Authorization"); self.end_headers()
    def do_GET(self):
        u=urlparse(self.path); p=u.path; q=parse_qs(u.query)
        if p in ("/","/index.html"): return self.serve_file("index.html","text/html; charset=utf-8")
        if p in ("/admin","/admin.html"): return self.serve_file("admin.html","text/html; charset=utf-8")
        if p=="/api/health": return jr(self,{"status":"ok","freepbx":HAS_FWCONSOLE})
        if p=="/api/pagers":
            qq=q.get("q",[""])[0]; return jr(self,buscar_pagers(qq) if qq else listar_pagers())
        if p=="/api/grupos":
            qq=q.get("q",[""])[0]; return jr(self,buscar_grupos(qq) if qq else listar_grupos())
        if p in ("/api/historial","/api/bitacora"):
            limit=min(int(q.get("limit",["50"])[0] or 50),500); offset=int(q.get("offset",["0"])[0] or 0)
            return jr(self, historial(q, limit, offset))
        if p in ("/api/historial/export","/api/bitacora/export"):
            rows=historial(q, 100000, 0)["rows"]
            out=io.StringIO(); out.write('\ufeff')
            w=csv.writer(out); w.writerow(["Fecha/Hora","Interno","Codigo","CapCode","Mensaje","Baudios","Estado","Observaciones"])
            for r in rows:
                w.writerow([r.get("fecha_hora"),r.get("interno_origen"),r.get("codigo"),r.get("cap_code"),
                            r.get("mensaje"),r.get("baudios"),r.get("estado"),r.get("observaciones")])
            data=out.getvalue().encode("utf-8")
            self.send_response(200); self.send_header("Content-Type","text/csv; charset=utf-8")
            self.send_header("Content-Disposition",'attachment; filename="historial_pocsag.csv"')
            self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data); return
        if p=="/api/config":
            if not self._guard(): return
            return jr(self, all_config())
        if p=="/api/extensions":
            if not self._guard(): return
            return jr(self, listar_extensiones())
        if p=="/api/pbx":
            sub=q.get("cmd",["status"])[0]; acmd=SAFE_CMDS.get(sub)
            if not acmd: return jr(self,{"error":"comando no permitido"},400)
            return jr(self,{"cmd":sub,"salida":ast_run(acmd)})
        self.send_response(404); self.end_headers()
    def do_POST(self):
        p=self.path
        try:
            if p=="/api/login":
                data=read_body(self); tok=login_validar(data.get("user",""),data.get("pass",""))
                return jr(self,{"token":tok}) if tok else jr(self,{"error":"usuario o clave incorrectos"},401)
            if p=="/api/logout":
                a=self.headers.get("Authorization","")
                if a.startswith("Bearer "): cerrar_sesion(a[7:].strip())
                return jr(self,{"ok":True})
            if p=="/api/enviar":
                data=read_body(self)
                return jr(self, enviar_mensaje(data.get("codigo",""),data.get("mensaje",""),data.get("origen","web")))
            if p=="/api/pagers":
                if not self._guard(): return
                return jr(self,{"id":crear_pager(read_body(self))})
            if p=="/api/grupos":
                if not self._guard(): return
                return jr(self,{"id":crear_grupo(read_body(self))})
            if p=="/api/pagers/import":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                rows,err=parse_import(body,self.headers.get("X-Filename",""))
                if err: return jr(self,{"error":err},400)
                return jr(self, importar_pagers(rows))
            if p=="/api/extensions":
                if not self._guard(): return
                return jr(self,{"id":crear_extension(read_body(self))})
            if p=="/api/extensions/aplicar":
                if not self._guard(): return
                if HAS_FWCONSOLE:
                    return jr(self,{"salida":"Modo FreePBX: gestione las extensiones desde el panel FreePBX (Applications -> Extensions)."})
                if not generar_pjsip_conf(): return jr(self,{"error":"no se pudo escribir /etc/asterisk/pjsip_pocsag.conf (permisos)"},400)
                return jr(self,{"salida":"Configuracion PJSIP regenerada y recargada.\n"+ast_run("pjsip reload")})
            if p=="/api/pbx/reload":
                if not self._guard(): return
                if HAS_FWCONSOLE: out=run_cmd(["fwconsole","reload"],timeout=60)
                else: out=ast_run("dialplan reload")+"\n"+ast_run("pjsip reload")
                return jr(self,{"salida":out})
            if p=="/api/pbx/restart":
                if not self._guard(): return
                if HAS_FWCONSOLE: out=run_cmd(["fwconsole","restart"],timeout=90)
                else: out=ast_run("core restart now")
                return jr(self,{"salida":out})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_PUT(self):
        parts=self.path.split("/"); data=read_body(self)
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                if len(parts)>4 and parts[4]=="estado":
                    toggle_pager(int(parts[3]),data.get("activo",1)); return jr(self,{"ok":True})
                actualizar_pager(int(parts[3]),data); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                actualizar_grupo(int(parts[3]),data); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                actualizar_extension(int(parts[3]),data); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="config":
                if not self._guard(): return
                for k,v in data.items(): set_config(k,str(v))
                return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_DELETE(self):
        parts=self.path.split("/")
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                borrar_pager(int(parts[3])); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                borrar_grupo(int(parts[3])); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                borrar_extension(int(parts[3])); return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG en http://{HOST}:{PORT} (FreePBX={'si' if HAS_FWCONSOLE else 'no'})")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()
EOF
mkx "${APP_DIR}/backend/app.py"

# --- frontend/index.html ---
cat > "${APP_DIR}/frontend/index.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG - Paginacion Hospitalaria</title>
<style>
:root{--bg:#0b1220;--panel:#111c30;--panel2:#15233c;--line:#1f3251;--txt:#e6edf7;--mut:#8aa0bd;--acc:#14b8a6;--acc2:#0ea5e9;--ok:#16a34a;--err:#dc2626;--warn:#d97706;--r:14px}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(180deg,#0b1220,#0a0f1c 60%);color:var(--txt);min-height:100vh}
.topbar{position:sticky;top:0;z-index:5;display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:.9rem 1.4rem;background:rgba(11,18,32,.85);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:.7rem;font-weight:700;letter-spacing:.2px}
.brand .logo{width:38px;height:38px;border-radius:11px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:20px}
.brand small{display:block;font-weight:500;color:var(--mut);font-size:.72rem;letter-spacing:.5px}
.pill{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .7rem;border-radius:999px;font-size:.74rem;background:rgba(20,184,166,.12);color:#5eead4;border:1px solid rgba(20,184,166,.3)}
.pill.off{background:rgba(220,38,38,.12);color:#fca5a5;border-color:rgba(220,38,38,.3)}
.dot{width:8px;height:8px;border-radius:50%;background:#34d399;box-shadow:0 0 8px #34d399}
.pill.off .dot{background:#f87171;box-shadow:0 0 8px #f87171}
.tabs{display:flex;gap:.4rem;padding:.8rem 1.4rem;max-width:980px;margin:0 auto;flex-wrap:wrap}
.tabs button{background:transparent;border:1px solid var(--line);color:var(--mut);border-radius:10px;padding:.55rem 1.1rem;cursor:pointer;font-weight:600;font-size:.86rem;transition:.15s}
.tabs button.active{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff;border-color:transparent;box-shadow:0 4px 14px rgba(20,184,166,.3)}
main{max-width:980px;margin:0 auto;padding:.4rem 1.4rem 3rem}
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:1.4rem;margin-bottom:1.2rem;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.card h2{margin:0 0 1rem;font-size:1.05rem;display:flex;align-items:center;gap:.5rem}
.card h2 .ic{color:var(--acc)}
.field{margin-bottom:.9rem}
label{display:block;font-size:.74rem;color:var(--mut);margin-bottom:.3rem;font-weight:600;letter-spacing:.4px;text-transform:uppercase}
input,select,textarea{width:100%;background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:10px;padding:.6rem .7rem;font-size:.92rem;outline:none;transition:.15s}
input:focus,select:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(20,184,166,.15)}
.row{display:flex;gap:.7rem;flex-wrap:wrap}
.row>*{flex:1;min-width:140px}
.btn{cursor:pointer;border:none;border-radius:10px;padding:.6rem 1.1rem;font-weight:700;font-size:.88rem;transition:.15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:active{transform:translateY(1px)}
.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff;box-shadow:0 6px 18px rgba(20,184,166,.3)}
.btn-pri:hover{filter:brightness(1.08)}
.btn-sec{background:var(--panel2);color:var(--txt);border:1px solid var(--line)}
.btn-sec:hover{border-color:var(--acc)}
.btn-ok{background:var(--ok);color:#fff}.btn-del{background:var(--err);color:#fff}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th,td{text-align:left;padding:.55rem .5rem;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:.74rem;text-transform:uppercase;letter-spacing:.5px}
tbody tr:hover{background:rgba(20,184,166,.05)}
.badge{padding:.18rem .55rem;border-radius:999px;font-size:.72rem;font-weight:600}
.badge.ok{background:rgba(22,163,74,.18);color:#86efac}.badge.err{background:rgba(220,38,38,.18);color:#fca5a5}
.filters{display:flex;gap:.6rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:1rem}
.filters>*{flex:1;min-width:130px}
.filters .btn{flex:0 0 auto}
.combo{position:relative}
.combo input{width:100%}
.combo ul{position:absolute;z-index:6;left:0;right:0;margin-top:.2rem;background:var(--panel2);border:1px solid var(--line);border-radius:10px;max-height:280px;overflow:auto;list-style:none;padding:.3rem;box-shadow:0 12px 30px rgba(0,0,0,.4);display:none}
.combo ul.open{display:block}
.combo li{padding:.5rem .6rem;border-radius:7px;cursor:pointer;font-size:.85rem;display:flex;justify-content:space-between;gap:.5rem}
.combo li:hover{background:rgba(20,184,166,.12)}
.combo li .tg{font-size:.7rem;color:var(--acc);font-weight:700}
.pager{display:flex;justify-content:space-between;align-items:center;margin-top:1rem;color:var(--mut);font-size:.84rem;flex-wrap:wrap;gap:.6rem}
.pager button{background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:8px;padding:.35rem .8rem;cursor:pointer}
.pager button:disabled{opacity:.4;cursor:not-allowed}
.toast{margin-top:.8rem;padding:.7rem .9rem;border-radius:10px;font-size:.86rem;display:none}
.toast.show{display:block}
.toast.ok{background:rgba(22,163,74,.14);border:1px solid rgba(22,163,74,.4);color:#86efac}
.toast.err{background:rgba(220,38,38,.14);border:1px solid rgba(220,38,38,.4);color:#fca5a5}
.foot{max-width:980px;margin:0 auto;padding:0 1.4rem 2rem;color:var(--mut);font-size:.78rem;display:flex;justify-content:space-between;flex-wrap:wrap;gap:.6rem}
.foot a{color:var(--acc);text-decoration:none}
.tab{display:none}.tab.active{display:block}
@media(max-width:560px){.row>*{min-width:100%}.topbar{padding:.7rem 1rem}.main{padding:.4rem 1rem}}
</style></head>
<body>
<div class="topbar">
  <div class="brand"><div class="logo">🧭</div><div>POCSAG<small>paginacion hospitalaria</small></div></div>
  <span id="h" class="pill"><span class="dot"></span> en linea</span>
</div>
<div class="tabs">
  <button class="active" onclick="tab('enviar',this)">📨 Enviar mensaje</button>
  <button onclick="tab('hist',this)">🕘 Historial</button>
</div>
<main>
<div class="tab active" id="t-enviar"><div class="card">
  <h2><span class="ic">📨</span> Enviar mensaje a un codigo o grupo</h2>
  <div class="field"><label>Buscar destinatario (nombre, apellido, codigo o area)</label>
    <div class="combo" id="cmb">
      <input id="e_q" autocomplete="off" placeholder="Escriba para buscar...">
      <ul id="e_list"></ul>
    </div>
  </div>
  <div class="field"><label>Mensaje (alfanumerico)</label><textarea id="e_msg" rows="3" placeholder="Escriba el mensaje para el pager..."></textarea></div>
  <button class="btn btn-pri" onclick="enviar()">Enviar mensaje</button>
  <div id="e_res" class="toast"></div>
</div></div>
<div class="tab" id="t-hist"><div class="card">
  <h2><span class="ic">🕘</span> Historial de mensajes</h2>
  <div class="filters">
    <div><label>Desde</label><input id="b_desde" type="date"></div>
    <div><label>Hasta</label><input id="b_hasta" type="date"></div>
    <div><label>Codigo</label><input id="b_codigo" placeholder="ej 10"></div>
    <div><label>Interno</label><input id="b_interno" placeholder="ej 101"></div>
    <div><label>Estado</label><select id="b_estado"><option value="">Todos</option><option>enviado</option><option>error</option></select></div>
    <button class="btn btn-pri" onclick="loadHist(0)">Filtrar</button>
    <button class="btn btn-ok" onclick="exportHist()">⬇ Exportar Excel</button>
  </div>
  <div style="overflow-x:auto">
  <table><thead><tr><th>Fecha/Hora</th><th>Interno</th><th>Codigo</th><th>Cap</th><th>Mensaje</th><th>Estado</th></tr></thead><tbody id="bit"></tbody></table>
  </div>
  <div class="pager">
    <span id="pg_info">—</span>
    <div><button id="pg_prev" onclick="pgGo(-1)">← Anterior</button> <button id="pg_next" onclick="pgGo(1)">Siguiente →</button></div>
  </div>
</div></div>
</main>
<div class="foot"><span>Sistema POCSAG · VoIP a pager</span><a href="/admin">Acceso administradores →</a></div>
<script>
const PG=50; let offset=0, total=0, chosen=null;
function tab(id,el){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));document.getElementById('t-'+id).classList.add('active');el.classList.add('active');if(id==='hist')loadHist(0);}
function toast(ok,msg){const t=document.getElementById('e_res');t.className='toast show '+(ok?'ok':'err');t.textContent=msg;}
async function buscarDest(q){
  const [pe,gr]=await Promise.all([fetch('/api/pagers'+(q?('?q='+encodeURIComponent(q)):'')).then(r=>r.json()),fetch('/api/grupos'+(q?('?q='+encodeURIComponent(q)):'')).then(r=>r.json())]);
  const out=[];
  (pe||[]).forEach(x=>out.push({codigo:x.codigo,label:`${x.nombre||''} ${x.apellido||''}`.trim()||x.codigo,sub:`${x.area||x.cap_code} · cap ${x.cap_code}`,tipo:'pager'}));
  (gr||[]).forEach(x=>out.push({codigo:x.codigo,label:x.nombre||x.codigo,sub:`GRUPO · ${(x.miembros||[]).length} pagers`,tipo:'grupo'}));
  return out;
}
const eq=document.getElementById('e_q'),elist=document.getElementById('e_list');
let btimer=null;
eq.addEventListener('input',()=>{clearTimeout(btimer);btimer=setTimeout(async()=>{const r=await buscarDest(eq.value.trim());renderList(r);},180);});
eq.addEventListener('focus',()=>{if(elist.innerHTML)elist.classList.add('open');});
function renderList(r){elist.innerHTML=r.map(x=>`<li onclick="pickDest('${x.codigo}','${(x.label||'').replace(/'/g,"")}')" data-c="${x.codigo}"><span>${x.label} <span style="color:var(--mut);font-size:.8rem">${x.codigo}</span></span><span class="tg">${x.tipo}</span></li>`).join('');elist.classList.toggle('open',r.length>0);}
function pickDest(codigo,label){chosen=codigo;eq.value=label+' ('+codigo+')';elist.classList.remove('open');}
document.addEventListener('click',e=>{if(!document.getElementById('cmb').contains(e.target))elist.classList.remove('open');});
async function enviar(){
  const codigo=chosen, mensaje=document.getElementById('e_msg').value.trim();
  if(!codigo){toast(false,'Seleccione un destinatario de la lista.');return;}
  if(!mensaje){toast(false,'Escriba un mensaje.');return;}
  const r=await fetch('/api/enviar',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({codigo,mensaje,origen:'web'})}).then(r=>r.json());
  if(r.status==='enviado'){toast(true,'Mensaje enviado correctamente.');document.getElementById('e_msg').value='';loadHist(offset);}else toast(false,'Error: '+(r.detalle||'no se pudo enviar'));
}
function histQuery(){const p=new URLSearchParams();p.set('limit',PG);p.set('offset',offset);
  const d=document.getElementById('b_desde').value,h=document.getElementById('b_hasta').value,c=document.getElementById('b_codigo').value,i=document.getElementById('b_interno').value,e=document.getElementById('b_estado').value;
  if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;}
const badge=e=>`<span class="badge ${e==='enviado'?'ok':'err'}">${e||'-'}</span>`;
async function loadHist(off){offset=off||0;const r=await fetch('/api/historial?'+histQuery()).then(r=>r.json());total=r.total||0;const rows=r.rows||[];
  document.getElementById('bit').innerHTML=rows.length?rows.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${badge(x.estado)}</td></tr>`).join(''):`<tr><td colspan="6" style="text-align:center;color:var(--mut);padding:1.4rem">Sin registros</td></tr>`;
  document.getElementById('pg_info').textContent=`${rows.length?offset+1:0}-${offset+rows.length} de ${total}`;
  document.getElementById('pg_prev').disabled=offset<=0;document.getElementById('pg_next').disabled=offset+PG>=total;}
function pgGo(d){loadHist(Math.max(0,offset+d*PG));}
function exportHist(){window.open('/api/historial/export?'+(function(){const p=new URLSearchParams();const d=document.getElementById('b_desde').value,h=document.getElementById('b_hasta').value,c=document.getElementById('b_codigo').value,i=document.getElementById('b_interno').value,e=document.getElementById('b_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;})(),'_blank');}
async function health(){try{const h=await fetch('/api/health').then(r=>r.json());const p=document.getElementById('h');p.className='pill '+(h.status==='ok'?'':'off');p.innerHTML=`<span class="dot"></span> ${h.status==='ok'?'en linea':'caido'}`;}catch(e){document.getElementById('h').className='pill off';document.getElementById('h').innerHTML='<span class="dot"></span> caido';}}
(async()=>{health();setInterval(health,15000);})();
</script></body></html>
EOF

# --- frontend/admin.html ---
cat > "${APP_DIR}/frontend/admin.html" <<'EOF'
<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>POCSAG - Admin</title>
<style>
:root{--bg:#0b1220;--panel:#111c30;--panel2:#15233c;--line:#1f3251;--txt:#e6edf7;--mut:#8aa0bd;--acc:#14b8a6;--acc2:#0ea5e9;--ok:#16a34a;--err:#dc2626;--warn:#d97706;--r:14px}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(180deg,#0b1220,#0a0f1c 60%);color:var(--txt);min-height:100vh}
.login{min-height:100vh;display:grid;place-items:center;padding:1rem}
.login .box{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:2.2rem;width:100%;max-width:380px;box-shadow:0 20px 60px rgba(0,0,0,.45)}
.login .logo{width:54px;height:54px;border-radius:16px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:28px;margin:0 auto .8rem}
.login h1{text-align:center;font-size:1.2rem;margin:.2rem 0 .2rem}.login p{text-align:center;color:var(--mut);font-size:.82rem;margin:0 0 1.4rem}
.app{display:flex;min-height:100vh}
.side{width:230px;background:var(--panel);border-right:1px solid var(--line);padding:1rem 0;display:flex;flex-direction:column;position:sticky;top:0;height:100vh}
.side .brand{display:flex;align-items:center;gap:.6rem;padding:.4rem 1rem 1rem;font-weight:700}
.side .brand .logo{width:34px;height:34px;border-radius:10px;display:grid;place-items:center;background:linear-gradient(135deg,var(--acc),var(--acc2));font-size:18px}
.side nav{flex:1;display:flex;flex-direction:column;gap:.2rem;padding:0 .6rem}
.side nav button{background:transparent;border:none;color:var(--mut);text-align:left;padding:.6rem .8rem;border-radius:10px;cursor:pointer;font-size:.9rem;font-weight:600;display:flex;align-items:center;gap:.6rem}
.side nav button:hover{background:var(--panel2);color:var(--txt)}
.side nav button.active{background:linear-gradient(135deg,rgba(20,184,166,.18),rgba(14,165,233,.18));color:var(--acc);border:1px solid rgba(20,184,166,.3)}
.side .bot{padding:.6rem}
.pill{display:inline-flex;align-items:center;gap:.4rem;padding:.3rem .7rem;border-radius:999px;font-size:.74rem;background:rgba(20,184,166,.12);color:#5eead4;border:1px solid rgba(20,184,166,.3)}
.content{flex:1;padding:1.4rem 2rem;max-width:1100px}
.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:1.4rem;flex-wrap:wrap;gap:.6rem}
.topbar h1{margin:0;font-size:1.3rem}
.card{background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:1.4rem;margin-bottom:1.2rem;box-shadow:0 10px 30px rgba(0,0,0,.25)}
.card h2{margin:0 0 1rem;font-size:1.05rem;display:flex;align-items:center;gap:.5rem;justify-content:space-between}
.toolbar{display:flex;gap:.6rem;flex-wrap:wrap;margin-bottom:1rem;align-items:center}
.search{flex:1;min-width:200px;position:relative}
.search input{width:100%}
label{display:block;font-size:.72rem;color:var(--mut);margin-bottom:.3rem;font-weight:600;letter-spacing:.4px;text-transform:uppercase}
input,select,textarea{width:100%;background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:10px;padding:.55rem .7rem;font-size:.9rem;outline:none;transition:.15s}
input:focus,select:focus,textarea:focus{border-color:var(--acc);box-shadow:0 0 0 3px rgba(20,184,166,.15)}
.row{display:flex;gap:.7rem;flex-wrap:wrap}.row>*{flex:1;min-width:140px}
.btn{cursor:pointer;border:none;border-radius:10px;padding:.55rem 1rem;font-weight:700;font-size:.85rem;transition:.15s;display:inline-flex;align-items:center;gap:.4rem}
.btn:active{transform:translateY(1px)}
.btn-pri{background:linear-gradient(135deg,var(--acc),var(--acc2));color:#fff}
.btn-pri:hover{filter:brightness(1.08)}
.btn-sec{background:var(--panel2);color:var(--txt);border:1px solid var(--line)}
.btn-sec:hover{border-color:var(--acc)}
.btn-ok{background:var(--ok);color:#fff}.btn-del{background:var(--err);color:#fff}.btn-warn{background:var(--warn);color:#fff}
.btn-sm{padding:.35rem .6rem;font-size:.78rem}
table{width:100%;border-collapse:collapse;font-size:.84rem}
th,td{text-align:left;padding:.5rem .5rem;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:.72rem;text-transform:uppercase;letter-spacing:.5px}
tbody tr:hover{background:rgba(20,184,166,.05)}
.badge{padding:.18rem .5rem;border-radius:999px;font-size:.7rem;font-weight:600}
.badge.ok{background:rgba(22,163,74,.18);color:#86efac}.badge.err{background:rgba(220,38,38,.18);color:#fca5a5}.badge.mut{background:var(--panel2);color:var(--mut)}
.sw{position:relative;width:42px;height:24px;border-radius:999px;background:#334155;cursor:pointer;transition:.15s;border:none}
.sw.on{background:var(--ok)}.sw::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;transition:.15s}.sw.on::after{left:21px}
.filters{display:flex;gap:.6rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:1rem}.filters>*{flex:1;min-width:130px}.filters .btn{flex:0 0 auto}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20;padding:1rem}
.modal.open{display:flex}.modal .card{width:100%;max-width:480px;margin:0}
.pager{display:flex;justify-content:space-between;align-items:center;margin-top:1rem;color:var(--mut);font-size:.84rem;flex-wrap:wrap;gap:.6rem}
.pager button{background:var(--panel2);border:1px solid var(--line);color:var(--txt);border-radius:8px;padding:.35rem .8rem;cursor:pointer}.pager button:disabled{opacity:.4;cursor:not-allowed}
pre{background:#0a0f1c;border:1px solid var(--line);border-radius:10px;padding:.8rem;overflow:auto;max-height:340px;font-size:.78rem;white-space:pre-wrap}
.drop{border:2px dashed var(--line);border-radius:14px;padding:1.6rem;text-align:center;color:var(--mut)}
.drop.hover{border-color:var(--acc);background:rgba(20,184,166,.06)}
.toast{margin-top:.8rem;padding:.7rem .9rem;border-radius:10px;font-size:.86rem;display:none}.toast.show{display:block}
.toast.ok{background:rgba(22,163,74,.14);border:1px solid rgba(22,163,74,.4);color:#86efac}.toast.err{background:rgba(220,38,38,.14);border:1px solid rgba(220,38,38,.4);color:#fca5a5}
.tab{display:none}.tab.active{display:block}
@media(max-width:760px){.app{flex-direction:column}.side{width:100%;height:auto;position:relative;flex-direction:row;overflow-x:auto}.side nav{flex-direction:row}.content{padding:1rem}}
</style></head>
<body>
<div class="login" id="login">
  <div class="box">
    <div class="logo">🧭</div>
    <h1>Panel de administracion</h1><p>POCSAG · paginacion hospitalaria</p>
    <div style="margin-bottom:.8rem"><label>Usuario</label><input id="lu" autocomplete="off"></div>
    <div style="margin-bottom:1.2rem"><label>Clave</label><input id="lp" type="password" autocomplete="off"></div>
    <button class="btn btn-pri" style="width:100%;justify-content:center" onclick="doLogin()">Ingresar</button>
    <div id="lerr" class="toast err"></div>
  </div>
</div>
<div class="app" id="app" style="display:none">
  <div class="side">
    <div class="brand"><div class="logo">🧭</div><div>POCSAG <small style="display:block;color:var(--mut);font-weight:500;font-size:.7rem">admin</small></div></div>
    <nav>
      <button class="active" onclick="tab('pagers',this)">👤 Pagers</button>
      <button onclick="tab('grupos',this)">👥 Grupos</button>
      <button onclick="tab('import',this)">📥 Importar</button>
      <button onclick="tab('ext',this)">☎ Extensiones</button>
      <button onclick="tab('hist',this)">🕘 Historial</button>
      <button onclick="tab('cfg',this)">⚙ Parametros</button>
      <button onclick="tab('pbx',this)">🔀 PBX</button>
    </nav>
    <div class="bot"><span id="h" class="pill">…</span><br><button class="btn btn-sec btn-sm" style="margin-top:.6rem;width:100%;justify-content:center" onclick="logout()">Salir</button></div>
  </div>
  <div class="content">
    <div class="topbar"><h1 id="tit">Pagers</h1></div>
    <div class="tab active" id="t-pagers"><div class="card"><h2><span>👤 Pagers individuales</span><button class="btn btn-pri btn-sm" onclick="openPager()">+ Nuevo pager</button></h2>
      <div class="toolbar"><div class="search"><input id="pq" placeholder="Buscar por nombre, apellido, codigo o area..."></div></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Codigo</th><th>CapCode</th><th>Nombre</th><th>Apellido</th><th>Area</th><th>Baud</th><th>Activo</th><th></th></tr></thead><tbody id="tb_pagers"></tbody></table></div></div></div>
    <div class="tab" id="t-grupos"><div class="card"><h2><span>👥 Grupos</span><button class="btn btn-pri btn-sm" onclick="openGrupo()">+ Nuevo grupo</button></h2>
      <div class="toolbar"><div class="search"><input id="gq" placeholder="Buscar grupo por codigo o nombre..."></div></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Codigo</th><th>Nombre</th><th>CapCodes</th><th>Baud</th><th></th></tr></thead><tbody id="tb_grupos"></tbody></table></div></div></div>
    <div class="tab" id="t-import"><div class="card"><h2>📥 Importar codigos desde Excel</h2>
      <p style="color:var(--mut);font-size:.85rem">Suba un archivo <b>.xlsx</b> o <b>.csv</b> con columnas: codigo, cap_code, nombre, apellido, area, baudios, descripcion. Los codigos existentes se actualizan.</p>
      <div class="drop" id="drop"><input type="file" id="ifile" accept=".xlsx,.csv" style="display:none"><div id="dftxt">Arrastre el archivo aqui o haga click para seleccionar</div></div>
      <div style="margin-top:1rem;display:flex;gap:.6rem;flex-wrap:wrap"><button class="btn btn-pri" id="impbtn" onclick="doImport()" disabled>Importar</button><a class="btn btn-sec" href="data:text/csv;base64,Y29kaWdvLGNhcF9jb2RlLG5vbWJyZSxhcGVsbGlkbyxhcmVhLGJhdWRpb3MsZGVzY3JpcGNpb24KMTAsMDAwMjAyMCxKdWFuLFBlcmV6LEd1YXJkaWEgTWVkaWNhLDEyMDAsTWVkaWNvIGRlIGd1YXJkaWEK" download="plantilla_pagers.csv">Descargar plantilla</a></div>
      <div id="imp_res" class="toast"></div></div></div>
    <div class="tab" id="t-ext"><div class="card"><h2><span>☎ Extensiones Asterisk</span><button class="btn btn-pri btn-sm" onclick="openExt()">+ Nueva extension</button></h2>
      <p style="color:var(--mut);font-size:.82rem;margin-top:-.5rem">Solo modo Asterisk nativo. En FreePBX gestione desde su panel.</p>
      <div style="display:flex;gap:.6rem;margin-bottom:.8rem"><button class="btn btn-warn btn-sm" onclick="aplicarExt()">Aplicar a Asterisk</button></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Numero</th><th>Clave</th><th>Contexto</th><th>Descripcion</th><th>Activo</th><th></th></tr></thead><tbody id="tb_ext"></tbody></table></div></div></div>
    <div class="tab" id="t-hist"><div class="card"><h2>🕘 Historial de mensajes</h2>
      <div class="filters"><div><label>Desde</label><input id="h_desde" type="date"></div><div><label>Hasta</label><input id="h_hasta" type="date"></div>
      <div><label>Codigo</label><input id="h_codigo"></div><div><label>Interno</label><input id="h_interno"></div>
      <div><label>Estado</label><select id="h_estado"><option value="">Todos</option><option>enviado</option><option>error</option></select></div>
      <button class="btn btn-pri" onclick="loadHist(0)">Filtrar</button><button class="btn btn-ok" onclick="exportHist()">⬇ Excel</button></div>
      <div style="overflow-x:auto"><table><thead><tr><th>Fecha/Hora</th><th>Interno</th><th>Codigo</th><th>Cap</th><th>Mensaje</th><th>Baud</th><th>Estado</th><th>Obs</th></tr></thead><tbody id="tb_hist"></tbody></table></div>
      <div class="pager"><span id="hg_info">—</span><div><button id="hg_prev" onclick="hgGo(-1)">← Anterior</button> <button id="hg_next" onclick="hgGo(1)">Siguiente →</button></div></div></div></div>
    <div class="tab" id="t-cfg"><div class="card"><h2>⚙ Parametros del sistema</h2>
      <div class="row"><div><label>Usuario admin</label><input id="c_admin_user"></div><div><label>Clave admin</label><input id="c_admin_pass" type="text"></div></div>
      <div class="row"><div><label>Timeout mensaje (seg)</label><input id="c_mensaje_timeout" type="number" step="1"></div><div><label>PTT pre-activo (seg)</label><input id="c_ptt_preactivo" type="number" step="0.1"></div>
      <div><label>Timeout digitos (seg)</label><input id="c_digit_timeout" type="number" step="1"></div><div><label>Timeout respuesta (seg)</label><input id="c_response_timeout" type="number" step="1"></div>
      <div><label>Modo prueba (1=si 0=no)</label><input id="c_test_mode" type="number" min="0" max="1"></div></div>
      <button class="btn btn-pri" onclick="saveConfig()">Guardar parametros</button><div id="cfg_res" class="toast"></div></div></div>
    <div class="tab" id="t-pbx"><div class="card"><h2>🔀 Gestion del PBX</h2>
      <div style="display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:.8rem"><button class="btn btn-sec btn-sm" onclick="pbx('status')">Estado</button><button class="btn btn-sec btn-sm" onclick="pbx('peers')">Endpoints</button><button class="btn btn-sec btn-sm" onclick="pbx('channels')">Canales</button><button class="btn btn-sec btn-sm" onclick="pbx('uptime')">Uptime</button><button class="btn btn-warn btn-sm" onclick="pbxReload()">Recargar config</button><button class="btn btn-del btn-sm" onclick="pbxRestart()">Reiniciar PBX</button></div>
      <pre id="pbx_out">—</pre></div></div>
  </div>
</div>
<div class="modal" id="mPager"><div class="card"><h2 id="mPT">Pager</h2>
  <div class="row"><div><label>Codigo (DTMF)</label><input id="p_codigo"></div><div><label>CapCode</label><input id="p_cap"></div></div>
  <div class="row"><div><label>Nombre</label><input id="p_nombre"></div><div><label>Apellido</label><input id="p_apellido"></div></div>
  <div class="row"><div><label>Area</label><input id="p_area"></div><div><label>Baudios</label><input id="p_baud" type="number" value="1200"></div></div>
  <label>Descripcion</label><input id="p_desc">
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="savePager()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mPager')">Cancelar</button></div></div></div>
<div class="modal" id="mGrupo"><div class="card"><h2 id="mGT">Grupo</h2>
  <div class="row"><div><label>Codigo (DTMF)</label><input id="g_codigo"></div><div><label>Baudios</label><input id="g_baud" type="number" value="1200"></div></div>
  <label>Nombre</label><input id="g_nombre">
  <label>CapCodes (uno por linea, max 20)</label><textarea id="g_miembros" rows="6"></textarea>
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="saveGrupo()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mGrupo')">Cancelar</button></div></div></div>
<div class="modal" id="mExt"><div class="card"><h2 id="mET">Extension</h2>
  <div class="row"><div><label>Numero</label><input id="x_numero"></div><div><label>Clave</label><input id="x_pass"></div></div>
  <label>Contexto</label><input id="x_ctx" value="pocsag-incoming">
  <label>Descripcion</label><input id="x_desc">
  <div style="display:flex;gap:.5rem;margin-top:.9rem"><button class="btn btn-pri" onclick="saveExt()">Guardar</button><button class="btn btn-sec" onclick="closeModal('mExt')">Cancelar</button></div></div></div>
<script>
let TOKEN=localStorage.getItem('pocsag_tok')||'';
let editP=null,editG=null,editX=null; const HPG=50; let hoff=0,htot=0;
function api(m,u,b,raw){const o={method:m,headers:{'Authorization':'Bearer '+TOKEN}};if(b!==undefined){if(raw){o.body=b;}else{o.headers['Content-Type']='application/json';o.body=JSON.stringify(b);}}return fetch(u,o).then(async r=>{if(r.status===401){logout(true);throw new Error('no autorizado');}const txt=await r.text();try{return JSON.parse(txt);}catch(e){return txt;}});}
function tab(id,el){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.side nav button').forEach(b=>b.classList.remove('active'));document.getElementById('t-'+id).classList.add('active');el.classList.add('active');const t={pagers:'Pagers',grupos:'Grupos',import:'Importar codigos',ext:'Extensiones',hist:'Historial',cfg:'Parametros',pbx:'PBX'};document.getElementById('tit').textContent=t[id]||'';if(id==='pagers')loadPagers();if(id==='grupos')loadGrupos();if(id==='ext')loadExt();if(id==='cfg')loadConfig();if(id==='hist')loadHist(0);if(id==='pbx')pbx('status');}
function openModal(id){document.getElementById(id).classList.add('open');}
function closeModal(id){document.getElementById(id).classList.remove('open');}
async function doLogin(){const u=document.getElementById('lu').value,p=document.getElementById('lp').value;document.getElementById('lerr').className='toast err';document.getElementById('lerr').textContent='';try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({user:u,pass:p})}).then(r=>r.json());if(r.token){TOKEN=r.token;localStorage.setItem('pocsag_tok',TOKEN);showApp();}else{document.getElementById('lerr').classList.add('show');document.getElementById('lerr').textContent=r.error||'error';}}catch(e){document.getElementById('lerr').classList.add('show');document.getElementById('lerr').textContent='error de conexion';}}
document.getElementById('lp').addEventListener('keydown',e=>{if(e.key==='Enter')doLogin();});
function logout(silent){TOKEN='';localStorage.removeItem('pocsag_tok');document.getElementById('app').style.display='none';document.getElementById('login').style.display='grid';if(!silent)document.getElementById('lp').value='';}
function showApp(){document.getElementById('login').style.display='none';document.getElementById('app').style.display='flex';tab('pagers',document.querySelector('.side nav button'));}
async function checkTok(){if(!TOKEN){return;}try{await api('GET','/api/extensions');showApp();}catch(e){}}
// Pagers
async function loadPagers(){const q=document.getElementById('pq').value.trim();const r=await api('GET','/api/pagers'+(q?('?q='+encodeURIComponent(q)):''));document.getElementById('tb_pagers').innerHTML=(r||[]).map(x=>`<tr><td>${x.codigo}</td><td>${x.cap_code}</td><td>${x.nombre||''}</td><td>${x.apellido||''}</td><td>${x.area||''}</td><td>${x.baudios}</td><td><button class="sw ${x.activo?'on':''}" onclick="toggleP(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openPager(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delP(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Sin resultados</td></tr>`;}
document.getElementById('pq').addEventListener('input',()=>{clearTimeout(window._pt);window._pt=setTimeout(loadPagers,200);});
async function toggleP(id,act){await api('PUT','/api/pagers/'+id+'/estado',{activo:act});loadPagers();}
async function openPager(id){editP=id||null;let x=null;if(id){const r=await api('GET','/api/pagers');x=(r||[]).find(i=>i.id===id);}['codigo','cap','nombre','apellido','area','desc'].forEach(f=>document.getElementById('p_'+f).value=x?x[f==='cap'?'cap_code':f]||'':'');document.getElementById('p_baud').value=x?x.baudios:1200;document.getElementById('mPT').textContent=id?'Editar pager':'Nuevo pager';openModal('mPager');}
async function savePager(){const d={codigo:document.getElementById('p_codigo').value,cap_code:document.getElementById('p_cap').value,nombre:document.getElementById('p_nombre').value,apellido:document.getElementById('p_apellido').value,area:document.getElementById('p_area').value,baudios:+document.getElementById('p_baud').value,descripcion:document.getElementById('p_desc').value,activo:1};if(editP)await api('PUT','/api/pagers/'+editP,d);else await api('POST','/api/pagers',d);closeModal('mPager');loadPagers();}
async function delP(id){if(confirm('Eliminar pager?')){await api('DELETE','/api/pagers/'+id);loadPagers();}}
// Grupos
async function loadGrupos(){const q=document.getElementById('gq').value.trim();const r=await api('GET','/api/grupos'+(q?('?q='+encodeURIComponent(q)):''));document.getElementById('tb_grupos').innerHTML=(r||[]).map(x=>`<tr><td>${x.codigo}</td><td>${x.nombre||''}</td><td>${(x.miembros||[]).join(', ')}</td><td>${x.baudios}</td><td><button class="btn btn-sec btn-sm" onclick="openGrupo(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delG(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="5" style="color:var(--mut);text-align:center;padding:1rem">Sin resultados</td></tr>`;}
document.getElementById('gq').addEventListener('input',()=>{clearTimeout(window._gt);window._gt=setTimeout(loadGrupos,200);});
async function openGrupo(id){editG=id||null;let x=null;if(id){const r=await api('GET','/api/grupos');x=(r||[]).find(i=>i.id===id);}document.getElementById('g_codigo').value=x?x.codigo:'';document.getElementById('g_nombre').value=x?x.nombre||'':'';document.getElementById('g_miembros').value=x?(x.miembros||[]).join('\n'):'';document.getElementById('g_baud').value=x?x.baudios:1200;document.getElementById('mGT').textContent=id?'Editar grupo':'Nuevo grupo';openModal('mGrupo');}
async function saveGrupo(){const d={codigo:document.getElementById('g_codigo').value,nombre:document.getElementById('g_nombre').value,baudios:+document.getElementById('g_baud').value,miembros:document.getElementById('g_miembros').value.split('\n').map(s=>s.trim()).filter(Boolean).slice(0,20)};if(editG)await api('PUT','/api/grupos/'+editG,d);else await api('POST','/api/grupos',d);closeModal('mGrupo');loadGrupos();}
async function delG(id){if(confirm('Eliminar grupo?')){await api('DELETE','/api/grupos/'+id);loadGrupos();}}
// Import
let impFile=null;const drop=document.getElementById('drop'),ifile=document.getElementById('ifile'),dftxt=document.getElementById('dftxt');
drop.addEventListener('click',()=>ifile.click());
ifile.addEventListener('change',e=>{impFile=e.target.files[0];dftxt.textContent=impFile.name;document.getElementById('impbtn').disabled=false;});
['dragover','dragenter'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add('hover');}));
['dragleave','drop'].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove('hover');}));
drop.addEventListener('drop',e=>{impFile=e.dataTransfer.files[0];dftxt.textContent=impFile.name;document.getElementById('impbtn').disabled=false;});
async function doImport(){if(!impFile)return;const buf=await impFile.arrayBuffer();const r=await api('POST','/api/pagers/import',buf,true);const t=document.getElementById('imp_res');t.className='toast show '+(r.error?'err':'ok');t.textContent=r.error?('Error: '+r.error):`Importados: ${r.importados} · Errores: ${r.errores}`;if(!r.error){loadPagers();}}
// Extensiones
async function loadExt(){const r=await api('GET','/api/extensions');document.getElementById('tb_ext').innerHTML=(r||[]).map(x=>`<tr><td>${x.numero}</td><td>${'*'.repeat((x.password||'').length||4)}</td><td>${x.contexto||''}</td><td>${x.descripcion||''}</td><td><button class="sw ${x.activo?'on':''}" onclick="toggleX(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openExt(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delX(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="6" style="color:var(--mut);text-align:center;padding:1rem">Sin extensiones</td></tr>`;}
async function toggleX(id,act){const r=await api('GET','/api/extensions');const x=(r||[]).find(i=>i.id===id);if(x)await api('PUT','/api/extensiones/'+id,{...x,activo:act});loadExt();}
async function openExt(id){editX=id||null;let x=null;if(id){const r=await api('GET','/api/extensions');x=(r||[]).find(i=>i.id===id);}document.getElementById('x_numero').value=x?x.numero:'';document.getElementById('x_pass').value=x?x.password||'':'';document.getElementById('x_ctx').value=x?x.contexto||'pocsag-incoming':'pocsag-incoming';document.getElementById('x_desc').value=x?x.descripcion||'':'';document.getElementById('mET').textContent=id?'Editar extension':'Nueva extension';openModal('mExt');}
async function saveExt(){const d={numero:document.getElementById('x_numero').value,password:document.getElementById('x_pass').value,contexto:document.getElementById('x_ctx').value,descripcion:document.getElementById('x_desc').value,activo:1};if(editX)await api('PUT','/api/extensiones/'+editX,d);else await api('POST','/api/extensions',d);closeModal('mExt');loadExt();}
async function delX(id){if(confirm('Eliminar extension?')){await api('DELETE','/api/extensiones/'+id);loadExt();}}
async function aplicarExt(){const r=await api('POST','/api/extensions/aplicar');alert(r.salida||r.error||'ok');}
// Historial
function hQuery(){const p=new URLSearchParams();p.set('limit',HPG);p.set('offset',hoff);const d=document.getElementById('h_desde').value,h=document.getElementById('h_hasta').value,c=document.getElementById('h_codigo').value,i=document.getElementById('h_interno').value,e=document.getElementById('h_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);return p;}
const badge=e=>`<span class="badge ${e==='enviado'?'ok':'err'}">${e||'-'}</span>`;
async function loadHist(off){hoff=off||0;const r=await api('GET','/api/historial?'+hQuery());htot=r.total||0;const rows=r.rows||[];document.getElementById('tb_hist').innerHTML=rows.length?rows.map(x=>`<tr><td>${x.fecha_hora}</td><td>${x.interno_origen||''}</td><td>${x.codigo}</td><td>${x.cap_code||''}</td><td>${x.mensaje||''}</td><td>${x.baudios||''}</td><td>${badge(x.estado)}</td><td>${x.observaciones||''}</td></tr>`).join(''):`<tr><td colspan="8" style="color:var(--mut);text-align:center;padding:1rem">Sin registros</td></tr>`;document.getElementById('hg_info').textContent=`${rows.length?hoff+1:0}-${hoff+rows.length} de ${htot}`;document.getElementById('hg_prev').disabled=hoff<=0;document.getElementById('hg_next').disabled=hoff+HPG>=htot;}
function hgGo(d){loadHist(Math.max(0,hoff+d*HPG));}
function exportHist(){const p=new URLSearchParams();const d=document.getElementById('h_desde').value,h=document.getElementById('h_hasta').value,c=document.getElementById('h_codigo').value,i=document.getElementById('h_interno').value,e=document.getElementById('h_estado').value;if(d)p.set('fecha_desde',d);if(h)p.set('fecha_hasta',h+'T23:59:59');if(c)p.set('codigo',c);if(i)p.set('interno',i);if(e)p.set('estado',e);window.open('/api/historial/export?'+p,'_blank');}
// Config
async function loadConfig(){const c=await api('GET','/api/config');['admin_user','admin_pass','mensaje_timeout','ptt_preactivo','digit_timeout','response_timeout','test_mode'].forEach(k=>{const el=document.getElementById('c_'+k);if(el&&c[k]!=null)el.value=c[k];});}
async function saveConfig(){const d={admin_user:document.getElementById('c_admin_user').value,admin_pass:document.getElementById('c_admin_pass').value,mensaje_timeout:document.getElementById('c_mensaje_timeout').value,ptt_preactivo:document.getElementById('c_ptt_preactivo').value,digit_timeout:document.getElementById('c_digit_timeout').value,response_timeout:document.getElementById('c_response_timeout').value,test_mode:document.getElementById('c_test_mode').value};await api('PUT','/api/config',d);const t=document.getElementById('cfg_res');t.className='toast show ok';t.textContent='Parametros guardados';setTimeout(()=>t.className='toast',2500);}
// PBX
async function pbx(cmd){const r=await api('GET','/api/pbx?cmd='+cmd);document.getElementById('pbx_out').textContent=r.salida||r.error||'';}
async function pbxReload(){if(!confirm('Recargar configuracion del PBX?'))return;const r=await api('POST','/api/pbx/reload');document.getElementById('pbx_out').textContent=r.salida||'';}
async function pbxRestart(){if(!confirm('Reiniciar PBX? Se cortaran llamadas activas.'))return;const r=await api('POST','/api/pbx/restart');document.getElementById('pbx_out').textContent=r.salida||'';}
async function health(){try{const h=await fetch('/api/health').then(r=>r.json());const p=document.getElementById('h');p.textContent=h.status==='ok'?'en linea':'caido';p.className='pill '+(h.status==='ok'?'':'off');}catch(e){}}
checkTok();health();setInterval(health,20000);
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
rm -f /etc/systemd/system/pocsag-{monitor,api}.service
systemctl daemon-reload
rm -f /etc/asterisk/extensions_pocsag.conf /etc/asterisk/pjsip_pocsag.conf
rm -f /var/lib/asterisk/agi-bin/pocsag_handler.py /var/lib/asterisk/agi-bin/pocsag_check.py
rm -f /etc/logrotate.d/pocsag
# limpia bloque POCSAG de extensions_custom.conf (FreePBX)
if [[ -f /etc/asterisk/extensions_custom.conf ]]; then
  sed -i '/; ===== POCSAG pocsag-server/,/; ===== FIN POCSAG =====/d' /etc/asterisk/extensions_custom.conf
fi
command -v fwconsole >/dev/null && fwconsole reload 2>/dev/null||true
if [[ $PURGE -eq 1 ]]; then rm -rf "$APP"; rm -f /var/log/pocsag-install.log
else cp "$APP/database/pocsag.db" /tmp/pocsag-backup.db 2>/dev/null||true; rm -rf "$APP"; fi
echo "Desinstalacion completa (FreePBX/Asterisk NO se quitan)."
EOF
mkx "${APP_DIR}/bin/uninstall.sh"

chown -R "${AST_USER}:${AST_USER}" "${APP_DIR}" 2>/dev/null || true

# ============================ 6. BASE DE DATOS =============================
echo "==> 6/10 Base de datos..."
python3 "${APP_DIR}/database/db_manager.py" init
chmod 640 "${APP_DIR}/database/pocsag.db" 2>/dev/null || true

# ============================ 7. DIALPLAN + AGI ============================
echo "==> 7/10 Dialplan + AGI..."
mkdir -p /var/lib/asterisk/agi-bin
cp "${APP_DIR}/agi/pocsag_handler.py" "${APP_DIR}/agi/pocsag_check.py" /var/lib/asterisk/agi-bin/
mkx /var/lib/asterisk/agi-bin/pocsag_handler.py
mkx /var/lib/asterisk/agi-bin/pocsag_check.py
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/agi-bin 2>/dev/null || true

ivr_file="${APP_DIR}/asterisk/pocsag_ivr.conf"
if [[ "$FREEPBX" == "1" ]]; then
  custom="/etc/asterisk/extensions_custom.conf"
  touch "$custom"
  sed -i '/; ===== POCSAG pocsag-server/,/; ===== FIN POCSAG =====/d' "$custom"
  { echo "; ===== POCSAG pocsag-server (no editar entre marcadores) ====="
    echo "[from-internal-custom]"
    echo "exten => 2184,1,NoOp(POCSAG paging)"
    echo " same => n,Goto(pocsag-incoming,2184,1)"
    echo ""
    cat "$ivr_file"
    echo "; ===== FIN POCSAG ====="; } >> "$custom"
  log "Dialplan integrado en extensions_custom.conf (FreePBX)."
else
  cp "$ivr_file" "${AST_ETC}/extensions_pocsag.conf"
  grep -q 'extensions_pocsag.conf' "${AST_ETC}/extensions.conf" 2>/dev/null || echo '#include extensions_pocsag.conf' >> "${AST_ETC}/extensions.conf"
  cp "${APP_DIR}/asterisk/pjsip_pocsag.conf" "${AST_ETC}/"
  grep -q 'pjsip_pocsag.conf' "${AST_ETC}/pjsip.conf" 2>/dev/null || echo '#include pjsip_pocsag.conf' >> "${AST_ETC}/pjsip.conf"
  log "Dialplan + endpoint 101 integrados (Asterisk nativo)."
fi

# ============================ 8. LOCUCIONES ===============================
echo "==> 8/10 Locuciones IVR..."
gen(){ local out="${APP_DIR}/audio/$1.gsm"; [[ -f "$out" ]] && return
  espeak -v es -s 160 "$2" -w "${out%.gsm}.wav" 2>/dev/null && sox "${out%.gsm}.wav" -r 8000 -c 1 "$out" 2>/dev/null || warn "No se pudo generar $1"
  rm -f "${out%.gsm}.wav"; }
gen despues-del-tono-marque-codigo "Despues del tono marque el numero de codigo"
gen despues-de-la-senal-su-mensaje "Despues de la senal marque su mensaje"
gen codigo-inexistente "Codigo inexistente"
gen marque-otro-codigo "Por favor marque otro codigo"
gen mensaje-vacio "Mensaje vacio"
gen confirmado "Mensaje enviado"
gen error-envio "Error de envio"
sox -n -r 8000 -c 1 "${APP_DIR}/audio/beep.gsm" synth 0.2 sine 1000 2>/dev/null || warn "beep no generado"
cp "${APP_DIR}"/audio/*.gsm /var/lib/asterisk/sounds/ 2>/dev/null || true
chown -R "${AST_USER}:${AST_USER}" /var/lib/asterisk/sounds 2>/dev/null || true

# ============================ 9. SYSTEMD + LOGROTATE ======================
echo "==> 9/10 Servicios + logrotate..."
cp "${APP_DIR}/services/"*.service /etc/systemd/system/
cat > /etc/logrotate.d/pocsag <<EOF
${APP_DIR}/logs/*.log { daily rotate 14 compress missingok notifempty }
EOF
systemctl daemon-reload
if [[ "$FREEPBX" == "1" ]]; then
  systemctl disable --now asterisk 2>/dev/null || true
  fwconsole start 2>/dev/null || warn "fwconsole start fallo"
  fwconsole reload 2>/dev/null || true
else
  systemctl enable --now asterisk 2>/dev/null || warn "Asterisk no pudo activarse"
  asterisk -rx "dialplan reload" 2>/dev/null || warn "No se pudo recargar dialplan"
  asterisk -rx "pjsip reload" 2>/dev/null || true
fi
systemctl enable --now pocsag-api 2>/dev/null || warn "API no pudo activarse"
systemctl enable --now pocsag-monitor 2>/dev/null || true

# ============================ 10. CHEQUEO ================================
echo "==> 10/10 Chequeo..."
bash "${APP_DIR}/scripts/healthcheck.sh" || warn "Healthcheck reporto problemas"

echo "--------------------------------------------"
log "Instalacion completada en ${APP_DIR}"
cat <<EOF

  MODO: $([ "$FREEPBX" = "1" ] && echo "FreePBX" || echo "Asterisk nativo")
  Panel publico (enviar + historial):  http://<servidor>:8080/
  Panel admin (gestion completa):       http://<servidor>:8080/admin
    Login por defecto: usuario=admin  clave=admin123  (CAMBIAR en Parametros)
  FreePBX (si aplica): http://<servidor>/    (admin por navegador)

PRUEBAS (Zoiper -> 101 -> 2184):

  SI tenes FreePBX:
    1) Entra al panel FreePBX (http://<servidor>/) -> Applications -> Extensions
    2) Add Extension (SIP/PJSIP) numero 101, pone un secret y guardas -> Apply Config
    3) En Zoiper: usuario 101, ese secret, host <servidor>:5060, UDP
    4) Marcas 2184 -> te atiende la IVR: codigo (ej 10) -> mensaje -> "Mensaje enviado"

  SI estas en Asterisk nativo:
    1) Edita /etc/asterisk/pjsip_pocsag.conf y cambia CAMBIAR_PASSWORD_101
    2) asterisk -rx "pjsip reload"
    3) Zoiper: usuario 101, esa clave, host <servidor>:5060, UDP
    4) Marcas 2184 -> IVR: codigo -> mensaje -> "Mensaje enviado"

  El sistema arranca en MODO PRUEBA (test_mode=1): omite PTT/audio y registra en bitacora.
  Para transmitir de verdad: panel web -> Parametros -> Modo prueba = 0 (y tener PTT/audio calibrados).

  Bitacora: sqlite3 /opt/pocsag-server/database/pocsag.db "SELECT * FROM bitacora ORDER BY id DESC LIMIT 5;"

  FreePBX no instalado? Ejecuta:  sudo INSTALL_FREEPBX=1 bash instalador.sh
  Desinstalar POCSAG: sudo /opt/pocsag-server/bin/uninstall.sh
EOF