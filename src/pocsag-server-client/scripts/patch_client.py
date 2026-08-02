#!/usr/bin/env python3
"""
patch_client.py - Parche post-install para modo cliente (v1.0client).
Modifica el app.py y admin.html YA DESPLEGADOS por instalador.sh para:
  - Agregar generar_pjsip_hospital_conf() y estado_registros_api() a app.py.
  - Agregar endpoint GET /api/extensions/status (estado de registro SIP).
  - Branchear /api/extensions/aplicar: en modo client genera pjsip_hospital.conf.
  - Agregar columna "Registro" (Registered / No registrado) en el admin.
  - Agregar campo "IP central del hospital" en Parametros.
Es idempotente: si ya esta parchado (marker presente), saltea.
No toca instalador.sh (que esta en el limite de lineas del platform).
"""
import sys

APP = "/opt/pocsag-server/backend/app.py"
ADM = "/opt/pocsag-server/frontend/admin.html"

# (marker, old, new)  -- marker = substring unico del NEW; si ya existe, se saltea
APP_PATCHES = [
    (
        "def generar_pjsip_hospital_conf",
        r'''def ast_run(cmd): return run_cmd(["asterisk","-rx",cmd])''',
        r'''def ast_run(cmd): return run_cmd(["asterisk","-rx",cmd])

def generar_pjsip_hospital_conf():
    exts=listar_extensiones()
    ip=all_config().get("hospital_pbx_ip","IP_HOSPITAL")
    conf="/etc/asterisk/pjsip_hospital.conf"
    lines=["; pjsip_hospital.conf - Generado por panel admin (modo cliente) - no editar a mano",""]
    for e in exts:
        if not e["activo"]: continue
        num=e["numero"]; ctx=e["contexto"] or "pocsag-incoming"; pw=e["password"] or ""
        lines+=[f"[reg-{num}]","type=registration",f"outbound_auth=auth-{num}",
                f"server_uri=sip:{ip}",f"client_uri=sip:{num}@{ip}","retry_interval=60","expiration=3600","",
                f"[auth-{num}]","type=auth","auth_type=userpass",f"username={num}",f"password={pw}","",
                f"[{num}]","type=endpoint",f"context={ctx}","disallow=all","allow=ulaw,alaw",
                f"auth=auth-{num}",f"aors={num}","",
                f"[{num}]","type=aor","max_contacts=1",""]
    try:
        with open(conf,"w") as f: f.write("\n".join(lines)+"\n")
        return True
    except PermissionError:
        return False

def estado_registros_api():
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
    return out''',
    ),
    (
        "/api/extensions/status",
        r'''            return jr(self, listar_extensiones())''',
        r'''            return jr(self, listar_extensiones())
        if p=="/api/extensions/status":
            if not self._guard(): return
            return jr(self, estado_registros_api())''',
    ),
    (
        'pocsag_mode")=="client"',
        r'''                if not generar_pjsip_conf(): return jr(self,{"error":"no se pudo escribir /etc/asterisk/pjsip_pocsag.conf (permisos)"},400)''',
        r'''                if all_config().get("pocsag_mode")=="client":
                    if not generar_pjsip_hospital_conf(): return jr(self,{"error":"no se pudo escribir pjsip_hospital.conf (permisos)"},400)
                    return jr(self,{"salida":"Configuracion cliente regenerada (pjsip_hospital.conf).\n"+ast_run("pjsip reload")+"\n"+ast_run("dialplan reload")})
                if not generar_pjsip_conf(): return jr(self,{"error":"no se pudo escribir /etc/asterisk/pjsip_pocsag.conf (permisos)"},400)''',
    ),
]

ADM_PATCHES = [
    (
        "<th>Registro</th>",
        r'''<th>Numero</th><th>Clave</th><th>Contexto</th><th>Descripcion</th><th>Activo</th><th></th></tr></thead><tbody id="tb_ext">''',
        r'''<th>Numero</th><th>Clave</th><th>Contexto</th><th>Descripcion</th><th>Registro</th><th>Activo</th><th></th></tr></thead><tbody id="tb_ext">''',
    ),
    (
        "extensions/status",
        r'''async function loadExt(){const r=await api('GET','/api/extensions');document.getElementById('tb_ext').innerHTML=(r||[]).map(x=>`<tr><td>${x.numero}</td><td>${'*'.repeat((x.password||'').length||4)}</td><td>${x.contexto||''}</td><td>${x.descripcion||''}</td><td><button class="sw ${x.activo?'on':''}" onclick="toggleX(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openExt(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delX(${x.id})">✕</button></td></tr>`).join('')||`<tr><td colspan="6" style="color:var(--mut);text-align:center;padding:1rem">Sin extensiones</td></tr>`;}''',
        r'''async function loadExt(){const [r,st]=await Promise.all([api('GET','/api/extensions'),api('GET','/api/extensions/status')]);const s=st||{};document.getElementById('tb_ext').innerHTML=(r||[]).map(x=>{const reg=s[x.numero]||'-';const rc=reg==='Registered'?'ok':reg==='No registrado'?'err':'mut';return `<tr><td>${x.numero}</td><td>${'*'.repeat((x.password||'').length||4)}</td><td>${x.contexto||''}</td><td>${x.descripcion||''}</td><td><span class="badge ${rc}">${reg}</span></td><td><button class="sw ${x.activo?'on':''}" onclick="toggleX(${x.id},${x.activo?0:1})"></button></td><td><button class="btn btn-sec btn-sm" onclick="openExt(${x.id})">✎</button> <button class="btn btn-del btn-sm" onclick="delX(${x.id})">✕</button></td></tr>`;}).join('')||`<tr><td colspan="7" style="color:var(--mut);text-align:center;padding:1rem">Sin extensiones</td></tr>`;}''',
    ),
    (
        "let extTimer=null",
        r'''let histTimer=null;function tab(id,el){''',
        r'''let histTimer=null;let extTimer=null;function tab(id,el){''',
    ),
    (
        "if(extTimer){clearInterval(extTimer)",
        r'''if(histTimer){clearInterval(histTimer);histTimer=null;}if(id==='pagers')loadPagers();''',
        r'''if(histTimer){clearInterval(histTimer);histTimer=null;}if(extTimer){clearInterval(extTimer);extTimer=null;}if(id==='pagers')loadPagers();''',
    ),
    (
        "extTimer=setInterval(loadExt",
        r'''if(id==='ext')loadExt();if(id==='cfg')''',
        r'''if(id==='ext'){loadExt();extTimer=setInterval(loadExt,5000);}if(id==='cfg')''',
    ),
    (
        "c_hospital_pbx_ip",
        r'''      <div class="row"><div><label>Usuario admin</label><input id="c_admin_user"></div><div><label>Clave admin</label><input id="c_admin_pass" type="text"></div></div>''',
        r'''      <div class="row"><div><label>Usuario admin</label><input id="c_admin_user"></div><div><label>Clave admin</label><input id="c_admin_pass" type="text"></div></div>
      <div class="row"><div><label>IP central del hospital (modo cliente)</label><input id="c_hospital_pbx_ip" placeholder="192.168.1.10"></div><div><label>Modo sistema</label><input id="c_pocsag_mode" readonly style="opacity:.7"></div></div>''',
    ),
    (
        "'hospital_pbx_ip','pocsag_mode'].forEach",
        r'''backup_email'].forEach(k=>{const el=document.getElementById('c_'+k);''',
        r'''backup_email','hospital_pbx_ip','pocsag_mode'].forEach(k=>{const el=document.getElementById('c_'+k);''',
    ),
    (
        "hospital_pbx_ip:document.getElementById('c_hospital_pbx_ip')",
        r'''backup_email:document.getElementById('c_backup_email').value};await api('PUT','/api/config',d);''',
        r'''backup_email:document.getElementById('c_backup_email').value,hospital_pbx_ip:document.getElementById('c_hospital_pbx_ip').value};await api('PUT','/api/config',d);''',
    ),
]


def patch_file(path, pairs):
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        print(f"[SKIP] {path} no existe (instalador base no corrio?)", file=sys.stderr)
        return
    applied = 0
    for marker, old, new in pairs:
        if marker in src:
            continue  # ya parchado
        if old not in src:
            print(f"[WARN] patron no encontrado en {path}: {old[:50]!r}", file=sys.stderr)
            continue
        src = src.replace(old, new, 1)
        applied += 1
    if applied:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        print(f"[OK] {path}: {applied} cambio(s) aplicados")
    else:
        print(f"[OK] {path}: sin cambios (ya parchado o patrones no encontrados)")


if __name__ == "__main__":
    patch_file(APP, APP_PATCHES)
    patch_file(ADM, ADM_PATCHES)