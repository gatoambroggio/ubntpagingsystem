# pocsag-server-client

Variante CLIENTE del sistema POCSAG para integracion con centrales VoIP hospitalarias existentes.

## Como funciona

1. Los internos 3000-3003 se registran contra la central VoIP del hospital (PJSIP registration).
2. Desde cualquier telefono de la central, al marcar 3000/3001/3002/3003, la central enruta la llamada al Asterisk del pocsag-server-client.
3. El Asterisk contesta con el IVR: "Despues del tono marque el numero de codigo" -> beep -> "Despues de la senal marque su mensaje" -> beep.
4. Si el codigo y mensaje son validos, el AGI codifica y transmite el POCSAG al pager correspondiente.

## Instalacion (una linea)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
```

## Arquitectura

El instalador:
1. Instala la base con `instalador.sh` (Asterisk + encoder + AGI + DB + servicios).
2. **Reemplaza** `app.py` y `admin.html` con versiones cliente standalone que incluyen:
   - `generar_pjsip_hospital_conf()` - genera los registros PJSIP contra el hospital.
   - `estado_registros_api()` - parsea `pjsip show registrations` y muestra Registered/No registrado en el panel.
3. Despliega `extensions_hospital.conf` (IVR autocontenido, no depende de `extensions_pocsag.conf`).
4. Migra la BD: elimina extensiones 101/2184-2187, crea 3000-3003, marca `pocsag_mode=client`.

## Configuracion post-install

Todo desde el panel admin (`http://servidor:8080/admin`):
1. **Parametros** -> IP central del hospital -> cargar la IP real -> Guardar.
2. **Extensiones** -> editar cada interno (3000-3003) con su clave real.
3. **Extensiones** -> Aplicar a Asterisk (regenera `pjsip_hospital.conf`).
4. La columna "Registro" muestra Registered / No registrado en vivo (auto-refresh cada 5s).

## Verificacion por consola

```bash
sudo asterisk -rx 'pjsip show registrations'
sudo asterisk -rx 'dialplan show pocsag-incoming'
```

## Archivos clave

| Archivo | Funcion |
|---------|---------|
| `backend/app.py` | API standalone con funciones cliente nativas |
| `frontend/admin.html` | Panel admin con columna Registro y campo IP hospital |
| `asterisk/extensions_hospital.conf` | IVR autocontenido (contexto pocsag-incoming + pocsag-ivr) |
| `asterisk/pjsip_hospital.conf` | Template inicial (se regenera desde el panel) |

## Version

1.0client