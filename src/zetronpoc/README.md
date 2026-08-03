# ZetronPOC v1.0

Sistema de paginacion hospitalaria POCSAG, modo **cliente** de una central **FreePBX**.

Registra hasta N internos SIP contra la central del hospital y, cuando alguien
marca uno de esos internos, contesta con un IVR (igual al 2184) que pide codigo y
mensaje y los envia por radio a los pagers POCSAG.

## Caracteristicas

- **Registro SIP contra FreePBX**: patron confiable, un endpoint PJSIP por
  extension (match por Request-URI user). Con `rewrite_contact` y
  `remove_existing` para NAT.
- **IVR que contesta de inmediato**: dialplan en un unico contexto
  (`from-hospital`), sin saltos entre contextos. Marca `*99` desde la central
  para probar que contesta (dos beeps).
- **Panel tipo FreePBX** en `/admin`: gestion de extensiones con estado de
  registro en vivo, pagers, grupos, envios, historial, control total de
  Asterisk (registros, recargar, forzar registro, consola), parametros del
  encoder y cola de envios.
- **Encoder POCSAG configurable** (baudios, preambulo, FSK, niveles, modo) todo
  desde la BD.
- **Instalador y desinstalador** completos.

## Instalacion

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash
```

Despues (todo desde el panel `http://localhost:8080/admin`, admin/admin123):

1. **Parametros** -> IP de la central FreePBX -> Guardar
2. **Extensiones** -> editar cada interno con su clave real -> **Aplicar a Asterisk**
3. La columna **Registro** debe quedar en `Registered`
4. Probar el IVR: marcar `*99` desde la central (debe escuchar dos beeps)

## Actualizar

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/instalador.sh | sudo bash -s -- --update
```

## Desinstalar (elimina todo, incluidas dependencias)

```bash
curl -fsSL https://raw.githubusercontent.com/gatoambroggio/ubntpagingsystem/main/src/zetronpoc/desinstalador.sh | sudo bash
```

## Verificacion por consola

```bash
sudo asterisk -rx "pjsip show registrations"
sudo asterisk -rx "dialplan show from-hospital"
``