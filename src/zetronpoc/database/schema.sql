-- schema.sql - ZetronPOC v1.0
CREATE TABLE IF NOT EXISTS config (clave TEXT PRIMARY KEY, valor TEXT);

CREATE TABLE IF NOT EXISTS extensiones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  numero TEXT UNIQUE NOT NULL,
  password TEXT NOT NULL,
  contexto TEXT DEFAULT 'from-hospital',
  descripcion TEXT,
  activo INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS pagers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  cap_code TEXT NOT NULL,
  nombre TEXT, apellido TEXT, area TEXT,
  baudios INTEGER DEFAULT 1200,
  descripcion TEXT, activo INTEGER DEFAULT 1,
  tipo TEXT DEFAULT 'individual'
);

CREATE TABLE IF NOT EXISTS grupos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT UNIQUE NOT NULL,
  nombre TEXT, baudios INTEGER DEFAULT 1200,
  activo INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS grupo_miembros (
  grupo_id INTEGER, cap_code TEXT, orden INTEGER,
  PRIMARY KEY (grupo_id, cap_code)
);

CREATE TABLE IF NOT EXISTS bitacora (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora TEXT, interno_origen TEXT, codigo TEXT, cap_code TEXT,
  mensaje TEXT, baudios INTEGER, estado TEXT, observaciones TEXT
);

CREATE TABLE IF NOT EXISTS cola_envios (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT, cap_code TEXT, mensaje TEXT, baudios INTEGER,
  origen TEXT, estado TEXT DEFAULT 'pendiente',
  intentos INTEGER DEFAULT 0, observaciones TEXT,
  fecha_encola TEXT, fecha_procesado TEXT, proximo_intento TEXT
);

CREATE TABLE IF NOT EXISTS plantillas (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre TEXT, mensaje TEXT, categoria TEXT,
  orden INTEGER DEFAULT 0, activo INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS envios_programados (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  codigo TEXT, mensaje TEXT, origen TEXT, tipo TEXT,
  fecha_programada TEXT, recurrencia_dia INTEGER,
  recurrencia_hora TEXT, proxima_ejecucion TEXT,
  ultima_ejecucion TEXT, activo INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS auditoria (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fecha_hora TEXT, usuario TEXT, accion TEXT,
  entidad TEXT, entidad_id TEXT, detalle TEXT, ip TEXT
);