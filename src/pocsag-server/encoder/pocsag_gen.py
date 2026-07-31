#!/usr/bin/env python3
"""
encoder/pocsag_gen.py - Genera un archivo .wav con la trama POCSAG.

Uso:
    python3 pocsag_gen.py <cap_code> <mensaje> <baudios> <salida.wav>

Backend por defecto: paquete Python 'pocsag'.
Alternativas documentadas en docs/SISTEMA_PAGERS_POCSAG.md (f4exb, rtl-pager).
"""
import sys
import subprocess


def encode_python(cap_code, mensaje, baudios, salida):
    """Usa la librería Python 'pocsag' (pip install pocsag)."""
    try:
        from pocsag import encode
    except ImportError:
        print("Falta el paquete 'pocsag'. Instalá con: pip3 install pocsag", file=sys.stderr)
        return 1
    # Tipo 'N' = mensaje numérico; 'A' = alfanumérico.
    encode(salida, [(int(cap_code), "N", mensaje)], baud=baudios)
    return 0


def encode_f4exb(cap_code, mensaje, baudios, salida):
    """Backend alternativo: binario 'pocsag' de f4exb (compilar aparte)."""
    binario = "/usr/local/bin/pocsag"
    try:
        subprocess.run(
            [binario, "--capcode", str(cap_code), "--baud", str(baudios),
             "--message", mensaje, "--out", salida],
            check=True,
        )
        return 0
    except FileNotFoundError:
        print(f"Binario '{binario}' no encontrado. Usar backend=python.", file=sys.stderr)
        return 1


def main():
    if len(sys.argv) != 5:
        print("Uso: pocsag_gen.py <cap_code> <mensaje> <baudios> <salida.wav>", file=sys.stderr)
        return 1
    cap_code, mensaje, baudios, salida = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    backend = os.environ.get("POCSAG_BACKEND", "python")
    if backend == "f4exb":
        return encode_f4exb(cap_code, mensaje, baudios, salida)
    return encode_python(cap_code, mensaje, baudios, salida)


import os
if __name__ == "__main__":
    sys.exit(main())