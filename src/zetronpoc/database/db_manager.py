#!/usr/bin/env python3
"""db_manager.py - ZetronPOC v1.0 - Gestor de BD y generador de config PJSIP.
Patron confiable: un endpoint por extension (match por Request-URI user).
Toda la config vive en la tabla config. Sin archivos estaticos externos."""
import sqlite3, os, secrets, time, datetime, subprocess, sys
from contextlib import contextmanager

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
DEFAULT_DB = os.path.join(APP_DIR, "database/zetronpoc.db")
_TOKENS = {}

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
        conn.execute("INSERT INTO config(clave,valor) VALUES(?,?) ON CONFLICT(clave) DO UPDATE SET valor=excluded.valor",(clave,valor))

def all_config(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return {r["clave"]:r["valor"] for r in conn.execute("SELECT * FROM config")}

# ===================== EXTENSIONES =====================
def listar_extensiones(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM extensiones ORDER BY numero")]

def crear_extension(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO extensiones (numero,password,contexto,descripcion,activo) VALUES (?,?,?,?,1)",
            (data["numero"],data.get("password",""),data.get("contexto","from-hospital") or "from-hospital",data.get("descripcion","")))
        return cur.lastrowid

def actualizar_extension(eid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE extensiones SET numero=?,password=?,contexto=?,descripcion=?,activo=? WHERE id=?",
            (data["numero"],data.get("password",""),data.get("contexto","from-hospital") or "from-hospital",
             data.get("descripcion",""),int(data.get("activo",1)),eid))

def borrar_extension(eid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM extensiones WHERE id=?",(eid,))

# ===================== GENERACION PJSIP =====================
def generar_pjsip_conf(db_path=DEFAULT_DB):
    """Genera /etc/asterisk/pjsip_zetronpoc.conf SELF-CONTAINED.
    Un endpoint por extension (nombrado con el numero). Match por Request-URI user.
    FreePBX envia INVITE a sip:NUMERO@zetronpoc -> matchea endpoint NUMERO -> context from-hospital."""
    cfg = all_config(db_path)
    ip = (cfg.get("hospital_pbx_ip") or "").strip()
    if not ip or ip == "IP_HOSPITAL":
        return False, "Configure la IP del hospital (FreePBX) en Parametros antes de aplicar"
    exts = listar_extensiones(db_path)
    activos = [e for e in exts if e["activo"]]
    if not activos:
        return False, "No hay extensiones activas. Habilite al menos una"
    for e in activos:
        if not (e.get("password") or "").strip():
            return False, f"La extension {e['numero']} no tiene clave configurada"
    transport_bind = cfg.get("transport_bind", "0.0.0.0:5060")
    transport_proto = cfg.get("transport_protocol", "udp")
    codecs = cfg.get("codecs", "ulaw,alaw")
    retry_interval = cfg.get("retry_interval", "60")
    expiration = cfg.get("expiration", "3600")
    pbx_port = (cfg.get("hospital_pbx_port", "5060") or "5060").strip()
    sip_target = ip if pbx_port == "5060" else f"{ip}:{pbx_port}"
    conf = "/etc/asterisk/pjsip_zetronpoc.conf"
    lines = [
        "; pjsip_zetronpoc.conf - Generado por panel admin - NO editar a mano",
        f"; IP central FreePBX: {ip}",
        f"; Internos activos: {', '.join(e['numero'] for e in activos)}",
        "; Patron: un endpoint por extension (match por Request-URI user)",
        "",
        "[transport-udp]",
        "type=transport",
        f"protocol={transport_proto}",
        f"bind={transport_bind}",
        "",
    ]
    for e in activos:
        num = e["numero"]; pw = e["password"].strip()
        lines += [
            f"; === Endpoint + registro del interno {num} ===",
            f"[{num}]",
            "type=endpoint",
            "context=from-hospital",
            "disallow=all",
            f"allow={codecs}",
            "transport=transport-udp",
            f"aors={num}",
            "trust_id_inbound=yes",
            "direct_media=no",
            "force_rport=yes",
            "rtp_symmetric=yes",
            "inband_progress=yes",
            "allow_subscribe=no",
            "rewrite_contact=yes",
            "",
            f"[{num}]",
            "type=aor",
            "max_contacts=1",
            "remove_existing=yes",
            "",
            f"[reg-{num}]",
            "type=registration",
            "transport=transport-udp",
            f"outbound_auth=auth-{num}",
            f"server_uri=sip:{sip_target}",
            f"client_uri=sip:{num}@{sip_target}",
            f"retry_interval={retry_interval}",
            f"expiration={expiration}",
            f"contact_user={num}",
            "",
            f"[auth-{num}]",
            "type=auth",
            "auth_type=userpass",
            f"username={num}",
            f"password={pw}",
            "",
        ]
    try:
        with open(conf, "w") as f: f.write("\n".join(lines) + "\n")
        return True, f"Generado: {len(activos)} endpoint(s) + registro(s) contra {ip}"
    except PermissionError:
        return False, "No se pudo escribir pjsip_zetronpoc.conf (permisos)"

# ===================== PAGERS / GRUPOS =====================
def listar_pagers(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        return [dict(r) for r in conn.execute("SELECT * FROM pagers ORDER BY codigo")]

def buscar_pagers(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if not q: return listar_pagers(db_path)
        like=f"%{q}%"
        return [dict(r) for r in conn.execute(
            "SELECT * FROM pagers WHERE codigo LIKE ? OR cap_code LIKE ? OR nombre LIKE ? OR apellido LIKE ? OR area LIKE ? ORDER BY codigo",
            (like,like,like,like,like))]

def crear_pager(data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO pagers (codigo,cap_code,nombre,apellido,area,baudios,descripcion,activo) VALUES (?,?,?,?,?,?,?,1)",
            (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
             data.get("area"),int(data.get("baudios",1200)),data.get("descripcion")))
        return cur.lastrowid

def actualizar_pager(pid, data, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET codigo=?,cap_code=?,nombre=?,apellido=?,area=?,baudios=?,descripcion=?,activo=? WHERE id=?",
            (data["codigo"],data["cap_code"],data.get("nombre"),data.get("apellido"),
             data.get("area"),int(data.get("baudios",1200)),data.get("descripcion"),int(data.get("activo",1)),pid))

def toggle_pager(pid, activo, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE pagers SET activo=? WHERE id=?",(int(activo),pid))

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

def buscar_grupos(q, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows = conn.execute("SELECT * FROM grupos ORDER BY codigo").fetchall() if not q else \
               conn.execute("SELECT * FROM grupos WHERE codigo LIKE ? OR nombre LIKE ? ORDER BY codigo",(f"%{q}%",f"%{q}%")).fetchall()
        out=[]
        for g in rows:
            miembros=[m["cap_code"] for m in conn.execute("SELECT cap_code FROM grupo_miembros WHERE grupo_id=? ORDER BY orden",(g["id"],)).fetchall()]
            out.append({**dict(g),"miembros":miembros})
        return out

def crear_grupo(data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO grupos (codigo,nombre,baudios,activo) VALUES (?,?,?,1)",
            (data["codigo"],data.get("nombre"),int(data.get("baudios",1200))))
        gid=cur.lastrowid
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))
        return gid

def actualizar_grupo(gid, data, db_path=DEFAULT_DB):
    caps = data.get("miembros",[])[:20]
    with get_conn(db_path) as conn:
        conn.execute("UPDATE grupos SET codigo=?,nombre=?,baudios=? WHERE id=?",
            (data["codigo"],data.get("nombre"),int(data.get("baudios",1200)),gid))
        conn.execute("DELETE FROM grupo_miembros WHERE grupo_id=?",(gid,))
        for i,c in enumerate(caps):
            conn.execute("INSERT OR IGNORE INTO grupo_miembros (grupo_id,cap_code,orden) VALUES (?,?,?)",(gid,c,i))

def borrar_grupo(gid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM grupos WHERE id=?",(gid,))

# ===================== DESTINO / ENVIO =====================
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
        conn.execute("INSERT INTO bitacora (fecha_hora,interno_origen,codigo,cap_code,mensaje,baudios,estado,observaciones) VALUES (?,?,?,?,?,?,?,?)",
            (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),interno,codigo,cap_code,mensaje,baudios,estado,obs))

# ===================== COLA =====================
def encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        cur=conn.execute("INSERT INTO cola_envios (codigo,cap_code,mensaje,baudios,origen,estado,fecha_encola) VALUES (?,?,?,?,?,?,?,?)",
            (codigo,caps,mensaje,baudios,origen,"pendiente",datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
        return cur.lastrowid

def enviar_mensaje(codigo, mensaje, origen="web", db_path=DEFAULT_DB):
    if not codigo or not mensaje: return {"status":"error","detalle":"falta codigo o mensaje"}
    dest = resolver_destino(codigo, db_path)
    if not dest: return {"status":"error","detalle":"codigo inactivo o inexistente"}
    caps, baudios, tipo = dest
    qid = encolar_mensaje(codigo, caps, mensaje, baudios, origen, db_path)
    return {"status":"encolado","detalle":f"mensaje encolado (id={qid})","id":qid}

def listar_cola(estado=None, limit=200, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        if estado:
            rows=conn.execute("SELECT * FROM cola_envios WHERE estado=? ORDER BY id DESC LIMIT ?",(estado,limit))
        else:
            rows=conn.execute("SELECT * FROM cola_envios ORDER BY id DESC LIMIT ?",(limit,))
        return [dict(r) for r in rows]

def estado_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        counts={}
        for r in conn.execute("SELECT estado, COUNT(*) as c FROM cola_envios GROUP BY estado"):
            counts[r["estado"]]=r["c"]
        return counts

def reintentar_cola(cid, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("UPDATE cola_envios SET estado='pendiente', intentos=0, observaciones='', proximo_intento=NULL WHERE id=? AND estado IN ('error','fallido')",(cid,))

def limpiar_cola(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("DELETE FROM cola_envios WHERE estado='enviado'")

def procesar_siguiente_cola(db_path=DEFAULT_DB):
    handler="/var/lib/asterisk/agi-bin/pocsag_handler.py"
    if not os.path.exists(handler): handler=os.path.join(APP_DIR,"agi/pocsag_handler.py")
    with get_conn(db_path) as conn:
        row=conn.execute("SELECT * FROM cola_envios WHERE estado='pendiente' AND (proximo_intento IS NULL OR proximo_intento <= datetime('now','localtime')) ORDER BY id ASC LIMIT 1").fetchone()
        if not row: return None
        conn.execute("UPDATE cola_envios SET estado='enviando', intentos=intentos+1 WHERE id=?",(row["id"],))
        conn.commit()
    item=dict(row)
    try:
        env={**os.environ,"ZETRONPOC_WORKER":"1"}
        rc=subprocess.run([sys.executable,handler,item["origen"] or "cola",item["codigo"],item["mensaje"]],
            capture_output=True,text=True,timeout=120,env=env)
        ok = rc.returncode==0
        obs = "" if ok else (rc.stderr or rc.stdout or "fallo").strip()[:200]
    except Exception as e:
        ok=False; obs=str(e)[:200]
    with get_conn(db_path) as conn:
        if ok:
            conn.execute("UPDATE cola_envios SET estado='enviado', fecha_procesado=datetime('now','localtime'), observaciones='', proximo_intento=NULL WHERE id=?",(item["id"],))
        else:
            intentos=item["intentos"]+1
            if intentos < 3:
                conn.execute("UPDATE cola_envios SET estado='pendiente', fecha_procesado=datetime('now','localtime'), observaciones=?, proximo_intento=datetime('now','localtime','+10 seconds') WHERE id=?",(obs,item["id"]))
            else:
                conn.execute("UPDATE cola_envios SET estado='fallido', fecha_procesado=datetime('now','localtime'), observaciones=?, proximo_intento=NULL WHERE id=?",(obs,item["id"]))
    return item["id"]

# ===================== HISTORIAL =====================
def historial(filtros, limit=50, offset=0, db_path=DEFAULT_DB):
    def val(v): return v[0] if isinstance(v,list) else v
    where=[]; args=[]
    if filtros.get("fecha_desde"): where.append("fecha_hora >= ?"); args.append(val(filtros["fecha_desde"]))
    if filtros.get("fecha_hasta"): where.append("fecha_hora <= ?"); args.append(val(filtros["fecha_hasta"]))
    for k,col in (("codigo","codigo"),("estado","estado"),("interno","interno_origen")):
        v=filtros.get(k); v=val(v) if v else ""
        if v: where.append(f"{col} LIKE ?"); args.append(f"%{v}%")
    wsql=(" WHERE "+" AND ".join(where)) if where else ""
    with get_conn(db_path) as conn:
        total=conn.execute("SELECT COUNT(*) AS c FROM bitacora"+wsql,args).fetchone()["c"]
        rows=[dict(r) for r in conn.execute("SELECT * FROM bitacora"+wsql+" ORDER BY id DESC LIMIT ? OFFSET ?",args+[limit,offset])]
    return {"rows":rows,"total":total,"limit":limit,"offset":offset}

# ===================== AUTH =====================
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

# ===================== AUDITORIA / STATS / LOGS =====================
def registrar_auditoria(usuario, accion, entidad, entidad_id, detalle, ip="", db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        conn.execute("INSERT INTO auditoria (fecha_hora,usuario,accion,entidad,entidad_id,detalle,ip) VALUES (?,?,?,?,?,?,?)",
            (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),usuario or "sistema",accion,entidad,str(entidad_id or ""),detalle or "",ip or ""))

def listar_auditoria(limit=200, offset=0, db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        rows=[dict(r) for r in conn.execute("SELECT * FROM auditoria ORDER BY id DESC LIMIT ? OFFSET ?",(limit,offset))]
        total=conn.execute("SELECT COUNT(*) AS c FROM auditoria").fetchone()["c"]
    return {"rows":rows,"total":total}

def estadisticas(db_path=DEFAULT_DB):
    with get_conn(db_path) as conn:
        total_env=conn.execute("SELECT COUNT(*) AS c FROM bitacora").fetchone()["c"]
        total_ok=conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='enviado'").fetchone()["c"]
        total_err=conn.execute("SELECT COUNT(*) AS c FROM bitacora WHERE estado='error'").fetchone()["c"]
    return {"total_enviados":total_env,"total_ok":total_ok,"total_err":total_err}

def leer_logs(tipo, limit=200, db_path=DEFAULT_DB):
    paths={"asterisk":"/var/log/asterisk/messages","api":os.path.join(APP_DIR,"logs/api.log"),
           "cola":os.path.join(APP_DIR,"logs/cola.log")}
    path=paths.get(tipo)
    if not path or not os.path.exists(path): return {"lineas":[],"path":path or "desconocido"}
    try:
        with open(path,"r",errors="replace") as f: lineas=f.readlines()[-limit:]
        return {"lineas":[l.rstrip() for l in lineas],"path":path}
    except Exception as e:
        return {"lineas":[],"path":path,"error":str(e)}

def backup_db(db_path=DEFAULT_DB):
    import shutil, time
    backup_dir=os.path.join(os.path.dirname(db_path),"backups")
    os.makedirs(backup_dir, exist_ok=True)
    ts=time.strftime("%Y%m%d_%H%M%S")
    bf=os.path.join(backup_dir, f"zetronpoc_backup_{ts}.db")
    shutil.copy2(db_path, bf)
    return bf

def restore_db(file_data, db_path=DEFAULT_DB):
    import shutil
    bk=db_path+".pre_restore"
    if os.path.exists(db_path): shutil.copy2(db_path, bk)
    with open(db_path,"wb") as f: f.write(file_data)
    return bk

if __name__ == "__main__":
    if len(sys.argv)>1 and sys.argv[1]=="init":
        init_db(); print("Base de datos ZetronPOC inicializada.")