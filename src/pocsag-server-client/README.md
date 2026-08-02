# pocsag-server-client v1.0client

Sistema de paginación hospitalaria POCSAG — **variante cliente**.

A diferencia del servidor autónomo (`pocsag-server`), esta versión **no es una central telefónica propia**. Se comporta como 4 internos VoIP (3000-3003) que se registran contra la central existente del hospital, y cuando alguien del hospital marca 177, la central enruta la llamada a uno de estos internos, que dispara el IVR de paginación.

## Arquitectura

```
[Hospital PBX] <--SIP Register-- [Ubuntu / Asterisk (pocsag-server-client)]
      |                                |
      |  marca 177                      |  4 internos: 3000, 3001, 3002, 3003
      +----------------------------->   |  cualquiera atiende -> IVR 2184 -> AGI POCSAG
```

- **3000, 3001, 3002, 3003**: internos que el servidor Ubuntu registra en la central del hospital.
- **177**: número que el hospital enruta hacia cualquiera de los 4 internos libres.
- **2184**: IVR de paginación interno (mismo flujo que el servidor autónomo).

## Instalación

1. Instalar el sistema base (igual que `pocsag-server`):
   ```bash
   sudo bash instalador.sh
   ```

2. Copiar los archivos de configuración del cliente:
   ```bash
   sudo cp asterisk/pjsip_hospital.conf /etc/asterisk/
   sudo cp asterisk/extensions_pocsag.conf /etc/asterisk/extensions_pocsag.conf
   ```

3. Incluir el archivo hospital en `pjsip.conf` principal:
   ```bash
   echo "#include pjsip_hospital.conf" | sudo tee -a /etc/asterisk/pjsip.conf
   ```

4. Editar credenciales y IP del hospital (ver `asterisk/pjsip_hospital.conf`).

5. Recargar:
   ```bash
   sudo asterisk -rx "pjsip reload"
   sudo asterisk -rx "dialplan reload"
   ```

## Verificación

```bash
# Los 4 internos deben decir "Registered"
sudo asterisk -rx "pjsip show registrations"

# Llamar desde un interno del hospital al 177
# Debe escuchar: "marque el código" (IVR de paginación)
```

## Versión

**1.0client** — primera versión cliente (hospital integration).