#!/usr/bin/env python3
"""app.py - ZetronPOC v1.0 - API REST (stdlib http.server).
Gestiona extensiones (panel tipo FreePBX), config, PBX, envios y cola."""
import os, sys, json, csv, io, subprocess, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import (listar_extensiones, crear_extension, actualizar_extension, borrar_extension,
    generar_pjsip_conf, all_config, set_config,
    listar_pagers, buscar_pagers, crear_pager, actualizar_pager, toggle_pager, borrar_pager,
    listar_grupos, buscar_grupos, crear_grupo, actualizar_grupo, borrar_grupo,
    enviar_mensaje, historial, login_validar, verificar_token, cerrar_sesion,
    listar_cola, estado_cola, reintentar_cola, limpiar_cola,
    backup_db, restore_db, registrar_auditoria, listar_auditoria, estadisticas, leer_logs)

HOST=os.environ.get("ZETRONPOC_API_HOST","0.0.0.0")
PORT=int(os.environ.get("ZETRONPOC_API_PORT","8080"))
FRONT=os.path.join(APP_DIR,"frontend")

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

def estado_registros_api():
    exts=listar_extensiones()
    activos=[e["numero"] for e in exts if e["activo"]]
    out={n:"No registrado" for n in activos}
    try:
        r=subprocess.run(["asterisk","-rx","pjsip show registrations"],capture_output=True,text=True,timeout=10)
        text=r.stdout or ""
        if "No registrations" in text or not text.strip(): return out
        lines=text.splitlines()
        for i,line in enumerate(lines):
            for n in activos:
                if f"reg-{n}" in line:
                    ctx=" ".join(lines[i:i+6])
                    if "Registered" in ctx: out[n]="Registered"
                    elif "Rejected" in ctx: out[n]="Rechazado"
                    elif "Failed" in ctx: out[n]="Fallido"
                    elif "Request Sent" in ctx or "Unsent" in ctx: out[n]="Enviando"
                    elif "Stopped" in ctx: out[n]="Detenido"
                    break
    except Exception: pass
    return out

SAFE_CMDS={"status":"core show status","peers":"pjsip show endpoints","channels":"core show channels",
    "uptime":"core show uptime","dialplan":"dialplan show from-hospital","registrations":"pjsip show registrations",
    "aors":"pjsip show aors","contacts":"pjsip show contacts","transports":"pjsip show transports",
    "modules":"module show","pjsip_settings":"pjsip show settings"}

def diagnostico_sip():
    cfg=all_config()
    ip=(cfg.get("hospital_pbx_ip") or "").strip()
    port=(cfg.get("hospital_pbx_port") or "5060").strip()
    result={"ip":ip,"puerto":port,"pasos":[]}
    if not ip or ip=="IP_HOSPITAL":
        result["error"]="No hay IP del hospital configurada"; return result
    p=run_cmd(["ping","-c","3","-W","2",ip],timeout=10)
    result["pasos"].append({"paso":"Ping a FreePBX","ok":"0% packet loss" in p,"salida":p[-400:]})
    try:
        with open("/etc/asterisk/pjsip_zetronpoc.conf") as f: result["pjsip_conf"]=f.read()[-3000:]
    except Exception as e: result["pjsip_conf"]=f"Error: {e}"
    result["registros"]=ast_run("pjsip show registrations")
    result["transportes"]=ast_run("pjsip show transports")
    result["dialplan"]=ast_run("dialplan show from-hospital")
    log=run_cmd(["bash","-c","grep -i 'pjsip\\|from-hospital\\|agi' /var/log/asterisk/messages 2>/dev/null | tail -40"],timeout=5)
    result["log"]=log[-2000:] if log else "(sin log)"
    return result

class H(BaseHTTPRequestHandler):
    def _auth(self):
        a=self.headers.get("Authorization","")
        return verificar_token(a[7:].strip()) if a.startswith("Bearer ") else False
    def _guard(self):
        if not self._auth(): jr(self,{"error":"no autorizado"},401); return False
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
        if p=="/api/version": return jr(self,{"version":all_config().get("version","1.0")})
        if p=="/api/theme":
            c=all_config()
            return jr(self,{k:c.get(k,"") for k in ("theme_acc","theme_acc2","theme_bg","theme_panel")})
        if p=="/api/pagers":
            qq=q.get("q",[""])[0]; return jr(self, buscar_pagers(qq) if qq else listar_pagers())
        if p=="/api/grupos":
            qq=q.get("q",[""])[0]; return jr(self, buscar_grupos(qq) if qq else listar_grupos())
        if p=="/api/historial":
            limit=min(int(q.get("limit",["50"])[0] or 50),500); offset=int(q.get("offset",["0"])[0] or 0)
            return jr(self, historial(q, limit, offset))
        if p=="/api/config":
            if not self._guard(): return
            return jr(self, all_config())
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
        if p=="/api/pbx/diagnose":
            if not self._guard(): return
            return jr(self, diagnostico_sip())
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
        if p=="/api/auditoria":
            if not self._guard(): return
            limit=min(int(q.get("limit",["200"])[0] or 200),1000)
            return jr(self, listar_auditoria(limit))
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
                d=read_body(self); pid=crear_pager(d); self._audit("crear","pager",pid,f"codigo={d.get('codigo')}"); return jr(self,{"id":pid})
            if p=="/api/grupos":
                if not self._guard(): return
                d=read_body(self); gid=crear_grupo(d); self._audit("crear","grupo",gid,f"codigo={d.get('codigo')}"); return jr(self,{"id":gid})
            if p=="/api/extensions":
                if not self._guard(): return
                d=read_body(self); eid=crear_extension(d); self._audit("crear","extension",eid,f"numero={d.get('numero')}"); return jr(self,{"id":eid})
            if p=="/api/extensions/aplicar":
                if not self._guard(): return
                ok,msg=generar_pjsip_conf()
                if not ok: return jr(self,{"error":msg},400)
                return jr(self,{"salida":msg+"\n"+ast_run("pjsip reload")+"\n"+ast_run("pjsip send register")+"\n"+ast_run("dialplan reload")})
            if p=="/api/pbx/reload":
                if not self._guard(): return
                return jr(self,{"salida":ast_run("dialplan reload")+"\n"+ast_run("pjsip reload")})
            if p=="/api/pbx/restart":
                if not self._guard(): return
                return jr(self,{"salida":ast_run("core restart now")})
            if p=="/api/pbx/force-register":
                if not self._guard(): return
                return jr(self,{"salida":ast_run("pjsip send register")})
            if p=="/api/pbx/unregister":
                if not self._guard(): return
                return jr(self,{"salida":ast_run("pjsip unregister")})
            if p=="/api/pbx/run":
                if not self._guard(): return
                d=read_body(self); cmd=(d.get("cmd","") or "").strip()
                if not cmd: return jr(self,{"error":"comando vacio"},400)
                allowed=("pjsip show","pjsip send","pjsip unregister","pjsip reload","core show","core restart","dialplan show","dialplan reload","module show","module load","module unload")
                if not any(cmd.lower().startswith(a) for a in allowed):
                    return jr(self,{"error":"comando no permitido"},400)
                return jr(self,{"salida":ast_run(cmd)})
            if p=="/api/cola/reintentar":
                if not self._guard(): return
                d=read_body(self); reintentar_cola(int(d["id"])); return jr(self,{"ok":True})
            if p=="/api/cola/limpiar":
                if not self._guard(): return
                limpiar_cola(); return jr(self,{"ok":True})
            if p=="/api/db/restore":
                if not self._guard(): return
                ln=int(self.headers.get("Content-Length",0)); body=self.rfile.read(ln)
                try:
                    bk=restore_db(body); return jr(self,{"ok":True,"backup":bk})
                except Exception as e: return jr(self,{"error":str(e)},500)
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
                actualizar_extension(int(parts[3]),data); self._audit("editar","extension",parts[3],f"numero={data.get('numero')}"); return jr(self,{"ok":True})
            if parts[1]=="api" and parts[2]=="config":
                if not self._guard(): return
                for k,v in data.items(): set_config(k,str(v))
                self._audit("editar","config","-",f"claves={list(data.keys())}"); return jr(self,{"ok":True})
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
                borrar_extension(int(parts[3])); self._audit("eliminar","extension",parts[3],""); return jr(self,{"ok":True})
            self.send_response(404); self.end_headers()
        except Exception as e: return jr(self,{"error":str(e)},400)
    def log_message(self,*a): pass

if __name__=="__main__":
    print(f"API ZetronPOC en http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST,PORT),H).serve_forever()