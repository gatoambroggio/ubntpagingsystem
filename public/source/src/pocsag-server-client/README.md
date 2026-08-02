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

## Instalación (una línea desde GitHub)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash
```

El instalador:
1. Descarga y ejecuta el sistema base POCSAG (`instalador.sh`).
2. Descarga `pjsip_hospital.conf` (4 registros 3000-3003) y `extensions_hospital.conf` (ruteo 177/3000-3003 → IVR 2184).
3. Los incluye en `pjsip.conf` y `extensions.conf` sin pisar la config que el panel admin regenera.
4. Marca la versión `1.0client` en la base y recarga Asterisk.

Actualizar solo la config cliente (sin reinstalar la base):
```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/instalador_client.sh | sudo bash -s -- --update
```

### Después de instalar
Editar las credenciales reales del hospital:
```bash
sudo nano /etc/asterisk/pjsip_hospital.conf   # reemplazar IP_HOSPITAL y passwords
sudo asterisk -rx "pjsip reload"
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