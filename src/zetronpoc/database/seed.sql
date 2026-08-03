-- seed.sql - ZetronPOC v1.0 - datos por defecto
INSERT OR IGNORE INTO config(clave,valor) VALUES('admin_user','admin');
INSERT OR IGNORE INTO config(clave,valor) VALUES('admin_pass','admin123');
INSERT OR IGNORE INTO config(clave,valor) VALUES('pocsag_mode','client');
INSERT OR IGNORE INTO config(clave,valor) VALUES('hospital_pbx_ip','192.168.2.97');
INSERT OR IGNORE INTO config(clave,valor) VALUES('hospital_pbx_port','5060');
INSERT OR IGNORE INTO config(clave,valor) VALUES('transport_bind','0.0.0.0:5060');
INSERT OR IGNORE INTO config(clave,valor) VALUES('transport_protocol','udp');
INSERT OR IGNORE INTO config(clave,valor) VALUES('codecs','ulaw,alaw');
INSERT OR IGNORE INTO config(clave,valor) VALUES('retry_interval','60');
INSERT OR IGNORE INTO config(clave,valor) VALUES('expiration','3600');
INSERT OR IGNORE INTO config(clave,valor) VALUES('baudios_default','1200');
INSERT OR IGNORE INTO config(clave,valor) VALUES('preamble_bits','576');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_512_ms','750');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_1200_ms','1500');
INSERT OR IGNORE INTO config(clave,valor) VALUES('warmup_2400_ms','1500');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_deviation_khz','4.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_deviation_baseband_hz','450');
INSERT OR IGNORE INTO config(clave,valor) VALUES('fsk_levels','2');
INSERT OR IGNORE INTO config(clave,valor) VALUES('function_mode','alphanumeric');
INSERT OR IGNORE INTO config(clave,valor) VALUES('mensaje_timeout','10');
INSERT OR IGNORE INTO config(clave,valor) VALUES('digit_timeout','5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('response_timeout','30');
INSERT OR IGNORE INTO config(clave,valor) VALUES('test_mode','0');
INSERT OR IGNORE INTO config(clave,valor) VALUES('ptt_preactivo','0.5');
INSERT OR IGNORE INTO config(clave,valor) VALUES('version','1.0');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_acc','#0ea5e9');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_acc2','#6366f1');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_bg','#f4f7fb');
INSERT OR IGNORE INTO config(clave,valor) VALUES('theme_panel','#ffffff');

-- Extensiones 2000-2010 (claves placeholder: editar desde el panel)
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2000','CAMBIAR_PASSWORD_2000','from-hospital','Interno 2000',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2001','CAMBIAR_PASSWORD_2001','from-hospital','Interno 2001',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2002','CAMBIAR_PASSWORD_2002','from-hospital','Interno 2002',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2003','CAMBIAR_PASSWORD_2003','from-hospital','Interno 2003',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2004','CAMBIAR_PASSWORD_2004','from-hospital','Interno 2004',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2005','CAMBIAR_PASSWORD_2005','from-hospital','Interno 2005',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2006','CAMBIAR_PASSWORD_2006','from-hospital','Interno 2006',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2007','CAMBIAR_PASSWORD_2007','from-hospital','Interno 2007',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2008','CAMBIAR_PASSWORD_2008','from-hospital','Interno 2008',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2009','CAMBIAR_PASSWORD_2009','from-hospital','Interno 2009',1);
INSERT OR IGNORE INTO extensiones(numero,password,contexto,descripcion,activo) VALUES('2010','CAMBIAR_PASSWORD_2010','from-hospital','Interno 2010',1);

-- Pager de ejemplo
INSERT OR IGNORE INTO pagers(codigo,cap_code,nombre,area,baudios,descripcion,activo,tipo) VALUES('100','0001234','Prueba','General',1200,'',1,'individual');

-- Plantilla de ejemplo
INSERT OR IGNORE INTO plantillas(nombre,mensaje,categoria,orden,activo) VALUES('Emergencia','Codigo de emergencia - acuda inmediatamente','urgencia',1,1);