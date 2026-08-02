#!/usr/bin/env python3
"""
backend/app.py - API de gestion del sistema POCSAG (variante CLIENTE v1.0client)
- Registra internos 3000-3003 contra la central VoIP del hospital
- Cuando el hospital llama a esos internos, el IVR contesta y envia POCSAG
- Incluye generar_pjsip_hospital_conf() y estado_registros_api() nativos
"""
import os, sys, json, csv, io, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote
sys.path.insert(0, "/opt/pocsag-server")
from database.db_manager import (listar_pagers, buscar_pagers, crear_pager, actualizar_pager, borrar_pager,
    toggle_pager, importar_pagers, importar_grupos,
    listar_grupos, buscar_grupos, crear_grupo, actualizar_grupo, borrar_grupo,
    listar_extensiones, crear_extension, actualizar_extension, borrar_extension, generar_pjsip_conf, generar_dialplan_conf,
    all_config, set_config, historial, enviar_mensaje, login_validar, verificar_token, cerrar_sesion,
    listar_cola, estado_cola, reintentar_cola, limpiar_cola, procesar_siguiente_cola,
    backup_db, restore_db, enviar_email,
    listar_plantillas, crear_plantilla, actualizar_plantilla, borrar_plantilla,
    listar_programados, crear_programado, actualizar_programado, borrar_programado,
    registrar_auditoria, listar_auditoria, estadisticas, leer_logs, notificar_error)

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

def run_cmd(args, timeout=15):
    try:
        r=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
        return (r.stdout or "")+(r.stderr or "")
    except Exception as e:
        return f"Error: {e}"

def ast_run(cmd): return run_cmd(["asterisk","-rx",cmd])

# ===================== FUNCIONES MODO CLIENTE =====================
def generar_pjsip_hospital_conf():
    """Genera /etc/asterisk/pjsip_hospital.conf con los registros de los internos
    contra la central del hospital. Se llama desde /api/extensions/aplicar."""
    exts=listar_extensiones()
    ip=all_config().get("hospital_pbx_ip","IP_HOSPITAL")
    conf="/etc/asterisk/pjsip_hospital.conf"
    lines=["; pjsip_hospital.conf - Generado por panel admin (modo cliente) - no editar a mano",""]
    for e in exts:
        if not e["activo"]: continue
        num=e["numero"]; ctx=e["contexto"] or "pocsag-incoming"; pw=e["password"] or ""
        lines+=[
            f"[reg-{num}]","type=registration",f"outbound_auth=auth-{num}",
            f"server_uri=sip:{ip}",f"client_uri=sip:{num}@{ip}","retry_interval=60","expiration=3600","",
            f"[auth-{num}]","type=auth","auth_type=userpass",f"username={num}",f"password={pw}","",
            f"[{num}]","type=endpoint",f"context={ctx}","disallow=all","allow=ulaw,alaw",
            f"auth=auth-{num}",f"aors={num}","",
            f"[{num}]","type=aor","max_contacts=1","",
        ]
    try:
        with open(conf,"w") as f: f.write("\n".join(lines)+"\n")
        return True
    except PermissionError:
        return False

def estado_registros_api():
    """Devuelve {numero: 'Registered' | 'No registrado'} para cada extension activa.
    Parsea 'pjsip show registrations' buscando 'reg-3000' o ':3000@' en cada linea."""
    exts=listar_extensiones()
    activos=[e["numero"] for e in exts if e["activo"]]
    out={n:"No registrado" for n in activos}
    try:
        r=subprocess.run(["asterisk","-rx","pjsip show registrations"],capture_output=True,text=True,timeout=10)
        for line in (r.stdout or "").splitlines():
            if "Registered" not in line: continue
            for n in activos:
                if ("reg-%s"%n) in line or (":%s@"%n) in line:
                    out[n]="Registered"
    except Exception: pass
    return out

# ===================== FIN FUNCIONES CLIENTE =====================

SAFE_CMDS={"status":"core show status","version":"core show version","peers":"pjsip show endpoints",
           "channels":"core show channels","uptime":"core show uptime","dialplan":"dialplan show",
           "registrations":"pjsip show registrations"}

def rows_from_sheet(body, filename):
    name=(filename or "").lower(); rows=[]
    if name.endswith(".csv"):
        for r in csv.DictReader(io.StringIO(body.decode("utf-8-sig",errors="replace"))): rows.append(r)
    elif name.endswith(".xlsx"):
        try: import openpyxl
        except ImportError: return None,"openpyxl no instalado. Exporte como CSV."
        tf=tempfile.NamedTemporaryFile(suffix=".xlsx",delete=False); tf.write(body); tf.close()
        try:
            wb=openpyxl.load_workbook(tf.name, read_only=True); data=list(wb.active.iter_rows(values_only=True))
        finally: os.unlink(tf.name)
        if not data: return [],None
        headers=[str(h or "").strip().lower() for h in data[0]]
        for row in data[1:]: rows.append(dict(zip(headers,[("" if c is None else str(c)) for c in row])))
    elif name.endswith(".xls"):
        try: import xlrd
        except ImportError: return None,"xlrd no instalado. Exporte como CSV o XLSX."
        tf=tempfile.NamedTemporaryFile(suffix=".xls",delete=False); tf.write(body); tf.close()
        try:
            ws=xlrd.open_workbook(tf.name).sheet_by_index(0); data=[ws.row_values(i) for i in range(ws.nrows)]
        finally: os.unlink(tf.name)
        if not data: return [],None
        headers=[str(h or "").strip().lower() for h in data[0]]
        for row in data[1:]: rows.append(dict(zip(headers,[("" if c is None else str(c)) for c in row])))
    else:
        return None,"Formato no soportado. Use .xls, .xlsx o .csv"
    return rows,None

def parse_import(body, filename):
    rows,err=rows_from_sheet(body,filename)
    if err: return None,err
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

def parse_import_grupos(body, filename):
    rows,err=rows_from_sheet(body,filename)
    if err: return None,err
    def pick(r,*keys):
        for k in keys:
            if k in r and str(r[k]).strip()!="": return str(r[k]).strip()
        return ""
    norm=[]
    for r in rows:
        item={"codigo":pick(r,"codigo","code","id"),"nombre":pick(r,"nombre","name"),
              "baudios":pick(r,"baudios","baud") or "1200",
              "cap_codes":pick(r,"cap_codes","capcodes","caps","miembros","cap_code")}
        if item["codigo"] and item["cap_codes"]: norm.append(item)
    return norm,None

class H(BaseHTTPRequestHandler):
    def _auth(self):
        a=self.headers.get("Authorization","")
        return verificar_token(a[7:].strip()) if a.startswith("Bearer ") else False
    def _guard(self):
        if not self._auth():
            jr(self,{"error":"no autorizado"},401); return False
        return True
    def _audit(self, accion, entidad, eid, detalle):
        try:
            a=self.headers.get("Authorization","")
            tok=a[7:].strip() if a.startswith("Bearer ") else ""
            usuario="admin" if tok else "anonimo"
            ip=self.client_address[0] if self.client_address else ""
            registrar_auditoria(usuario,accion,entidad,eid,detalle,ip)
        except Exception: pass
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
        if p=="/api/health": return jr(self,{"status":"ok"})
        if p=="/api/version": return jr(self,{"version":all_config().get("version","1.0client")})
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
        if p=="/api/theme":
            c=all_config()
            return jr(self,{k:c.get(k,"") for k in ("theme_acc","theme_acc2","theme_bg","theme_panel","theme_font_heading","theme_font_body")})
        if p=="/api/config":
            if not self._guard(): return
            return jr(self, all_config())
        if p=="/api/smtp/log":
            if not self._guard(): return
            try:
                lf="/opt/pocsag-server/logs/smtp.log"
                if os.path.exists(lf):
                    lines=open(lf,encoding="utf-8",errors="ignore").read().splitlines()[-200:]
                else: lines=[]
                return jr(self, {"lines":lines})
            except Exception as e: return jr(self,{"lines":[],"error":str(e)})
        if p=="/api/smtp/log/clear":
            if not self._guard(): return
            try:
                open("/opt/pocsag-server/logs/smtp.log","w").close()
                return jr(self,{"ok":True})
            except Exception as e: return jr(self,{"error":str(e)})
        if p=="/api/extensions":
            if not self._guard(): return
            return jr(self, listar_extensiones())
        if p=="/api/extensions/status":
            if not self._guard(): return
            return jr(self, estado_registros_api())
        if p=="/api/pbx":
            sub=q.get("cmd",["status"])[0]; acmd=SAFE_CMDS.get(sub)
            if not acmd: return jr(self,{"error":"comando no permitido"},400)
            return jr(self,{"cmd":sub,"salida":ast_run(acmd)})
        if p=="/api/cola":
            if not self._guard(): return
            est=q.get("estado",[""])[0] if q.get("estado") else None
            return jr(self, listar_cola(est))
        if p=="/api/cola/estado":
            if not self._guard(): return
            return jr(self, estado_cola())
        if p=="/api/db/backup":
            if not self._guard(): return
            try:
                bf=backup_db()
                with open(bf,"rb") as f: data=f.read()
                self.send_response(200)
                self.send_header("Content-Type","application/octet-stream")
                self.send_header("Content-Disposition",f'attachment; filename="{os.path.basename(bf)}"')
                self.send_header("Content-Length",str(len(data))); self.end_headers()
                self.wfile.write(data)
            except Exception as e: return jr(self,{"error":str(e)},500)
            return
        if p=="/api/plantillas":
            return jr(self, listar_plantillas())
        if p=="/api/programados":
            if not self._guard(): return
            return jr(self, listar_programados())
        if p=="/api/auditoria":
            if not self._guard(): return
            limit=min(int(q.get("limit",["200"])[0] or 200),1000); offset=int(q.get("offset",["0"])[0] or 0)
            return jr(self, listar_auditoria(limit,offset))
        if p=="/api/stats":
            if not self._guard(): return
            return jr(self, estadisticas())
        if p=="/api/logs":
            if not self._guard(): return
            tipo=q.get("tipo",["api"])[0]; limit=min(int(q.get("limit",["200"])[0] or 200),1000)
            return jr(self, leer_logs(tipo,limit))
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
                d=read_body(self); pid=crear_pager(d)
                self._audit("crear","pager",pid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":pid})
            if p=="/api/grupos":
                if not self._guard(): return
                d=read_body(self); gid=crear_grupo(d)
                self._audit("crear","grupo",gid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":gid})
            if p=="/api/pagers/import":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                rows,err=parse_import(body,unquote(self.headers.get("X-Filename","")))
                if err: return jr(self,{"error":err},400)
                if not rows: return jr(self,{"error":"El archivo no tiene filas validas con codigo y cap_code"},400)
                return jr(self, importar_pagers(rows))
            if p=="/api/grupos/import":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                rows,err=parse_import_grupos(body,unquote(self.headers.get("X-Filename","")))
                if err: return jr(self,{"error":err},400)
                if not rows: return jr(self,{"error":"El archivo no tiene filas validas con codigo y cap_codes"},400)
                return jr(self, importar_grupos(rows))
            if p=="/api/extensions":
                if not self._guard(): return
                d=read_body(self); eid=crear_extension(d)
                self._audit("crear","extension",eid,f"numero={d.get('numero')}")
                return jr(self,{"id":eid})
            if p=="/api/plantillas":
                if not self._guard(): return
                d=read_body(self); pid=crear_plantilla(d)
                self._audit("crear","plantilla",pid,f"nombre={d.get('nombre')}")
                return jr(self,{"id":pid})
            if p=="/api/programados":
                if not self._guard(): return
                d=read_body(self); pid=crear_programado(d)
                self._audit("crear","programado",pid,f"codigo={d.get('codigo')}")
                return jr(self,{"id":pid})
            if p=="/api/extensions/aplicar":
                if not self._guard(): return
                # MODO CLIENTE: generar pjsip_hospital.conf + extensions_hospital.conf
                if all_config().get("pocsag_mode")=="client":
                    if not generar_pjsip_hospital_conf():
                        return jr(self,{"error":"no se pudo escribir pjsip_hospital.conf (permisos)"},400)
                    return jr(self,{"salida":"Configuracion cliente regenerada (pjsip_hospital.conf).\n"+ast_run("pjsip reload")+"\n"+ast_run("dialplan reload")})
                if not generar_pjsip_conf(): return jr(self,{"error":"no se pudo escribir /etc/asterisk/pjsip_pocsag.conf (permisos)"},400)
                generar_dialplan_conf()
                return jr(self,{"salida":"Configuracion PJSIP y dialplan regenerados.\n"+ast_run("pjsip reload")+"\n"+ast_run("dialplan reload")})
            if p=="/api/pbx/reload":
                if not self._guard(): return
                out=ast_run("dialplan reload")+"\n"+ast_run("pjsip reload")
                return jr(self,{"salida":out})
            if p=="/api/pbx/restart":
                if not self._guard(): return
                out=ast_run("core restart now")
                return jr(self,{"salida":out})
            if p=="/api/cola/reintentar":
                if not self._guard(): return
                d=read_body(self); reintentar_cola(int(d["id"]))
                return jr(self,{"ok":True})
            if p=="/api/cola/limpiar":
                if not self._guard(): return
                limpiar_cola()
                return jr(self,{"ok":True})
            if p=="/api/db/restore":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                try:
                    bk=restore_db(body)
                    return jr(self,{"ok":True,"backup":bk})
                except Exception as e: return jr(self,{"error":str(e)},500)
            if p=="/api/db/backup-email":
                if not self._guard(): return
                d=read_body(self)
                email=d.get("email","") or all_config().get("backup_email","")
                if not email: return jr(self,{"error":"no hay email configurado"},400)
                try:
                    bf=backup_db()
                    r=enviar_email(email,"Backup POCSAG","Backup de base de datos adjunto.",bf)
                    return jr(self, r, 200 if "ok" in r else 400)
                except Exception as e: return jr(self,{"error":str(e)},500)
            if p=="/api/smtp/test":
                if not self._guard(): return
                d=read_body(self)
                try:
                    r=enviar_email(d.get("email",""),"Prueba SMTP POCSAG","Si recibe este mensaje, SMTP funciona correctamente.")
                    return jr(self, r, 200 if "ok" in r else 400)
                except Exception as e: return jr(self,{"error":str(e)},500)
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_PUT(self):
        parts=self.path.split("/"); data=read_body(self)
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                if len(parts)>4 and parts[4]=="estado":
                    toggle_pager(int(parts[3]),data.get("activo",1)); self._audit("editar","pager",parts[3],f"activo={data.get('activo')}"); return jr(self,{"ok":True})
                actualizar_pager(int(parts[3]),data); self._audit("editar","pager",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                actualizar_grupo(int(parts[3]),data); self._audit("editar","grupo",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                actualizar_extension(int(parts[3]),data); self._audit("editar","extension",parts[3],f"numero={data.get('numero')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="plantillas" and len(parts)>3:
                if not self._guard(): return
                actualizar_plantilla(int(parts[3]),data); self._audit("editar","plantilla",parts[3],f"nombre={data.get('nombre')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="programados" and len(parts)>3:
                if not self._guard(): return
                actualizar_programado(int(parts[3]),data); self._audit("editar","programado",parts[3],f"codigo={data.get('codigo')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="config":
                if not self._guard(): return
                for k,v in data.items(): set_config(k,str(v))
                self._audit("editar","config","-",f"claves={list(data.keys())}")
                return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def do_DELETE(self):
        parts=self.path.split("/")
        try:
            if parts[1]=="api" and parts[2]=="pagers" and len(parts)>3:
                if not self._guard(): return
                borrar_pager(int(parts[3])); self._audit("eliminar","pager",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="grupos" and len(parts)>3:
                if not self._guard(): return
                borrar_grupo(int(parts[3])); self._audit("eliminar","grupo",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="extensiones" and len(parts)>3:
                if not self._guard(): return
                borrar_extension(int(parts[3])); self._audit("eliminar","extension",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="plantillas" and len(parts)>3:
                if not self._guard(): return
                borrar_plantilla(int(parts[3])); self._audit("eliminar","plantilla",parts[3],""); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="programados" and len(parts)>3:
                if not self._guard(): return
                borrar_programado(int(parts[3])); self._audit("eliminar","programado",parts[3],""); return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API POCSAG (cliente) en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()