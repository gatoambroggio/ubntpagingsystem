#!/usr/bin/env python3
"""pocsag_check.py - AGI que valida un codigo de pager en la BD.
Setea POCSAG_VALID=1/0 y POCSAG_MSJ_TIMEOUT (seg) para el dialplan."""
import sys, os
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
from db_manager import get_config, resolver_destino

def agi_set(v, val):
    sys.stdout.write(f'SET VARIABLE {v} "{val}"\n'); sys.stdout.flush()

def main():
    if len(sys.argv) < 2:
        agi_set("POCSAG_VALID", "0"); return
    codigo = str(sys.argv[1]).strip()
    dest = resolver_destino(codigo)
    if dest:
        agi_set("POCSAG_VALID", "1")
        to = get_config("mensaje_timeout", "10")
        agi_set("POCSAG_MSJ_TIMEOUT", str(to))
    else:
        agi_set("POCSAG_VALID", "0")

if __name__ == "__main__":
    try: main()
    except Exception:
        try: agi_set("POCSAG_VALID", "0")
        except: pass