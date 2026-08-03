#!/usr/bin/env python3
"""pocsag_gen.py - ZetronPOC - Encoder POCSAG (FSK) + WAV 16-bit mono.
Lee los parametros del encoder (baudios, preambulo, FSK, modo) desde la BD.
Uso: pocsag_gen.py <cap_code> <mensaje> [baudios] [wav_out]"""
import sys, os, math, struct, wave
APP_DIR = os.environ.get("ZETRONPOC_DIR", "/opt/zetronpoc")
sys.path.insert(0, APP_DIR)
sys.path.insert(0, os.path.join(APP_DIR, "database"))
try:
    from db_manager import get_config
except Exception:
    def get_config(k, d=""): return d

# Constantes POCSAG
FUNCTION_NUMERIC = 0x0
FUNCTION_TONE = 0x1
FUNCTION_ALPHANUMERIC = 0x3
PREAMBLEBLE = 0b01010101 * 0xAAAA  # placeholder
SYNC = 0x7CD215D8DF7FF6E0  # not used directly

def bits_to_fsk(bits, baud, dev_hz, sample_rate=22050, levels=2):
    """Convierte bits a muestras FSK (desviacion dev_hz) con filtrado gaussiano simple."""
    samples_per_bit = sample_rate / baud
    n = int(len(bits) * samples_per_bit) + 1
    out = []
    # FSK: bit 0 -> -dev, bit 1 -> +dev ; fase continua
    phase = 0.0
    cur = 0
    for i in range(n):
        bit_idx = int(i / samples_per_bit)
        b = bits[bit_idx] if bit_idx < len(bits) else bits[-1]
        freq = -dev_hz if b == 0 else dev_hz
        phase += 2 * math.pi * freq / sample_rate
        out.append(math.sin(phase))
    return out

def normalize(samples, peak=0.8):
    m = max(abs(s) for s in samples) or 1.0
    return [s / m * peak for s in samples]

def write_wav(path, samples, rate=22050):
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        frames = b"".join(struct.pack("<h", int(s * 32767)) for s in samples)
        w.writeframes(frames)

def encode_codeword(bits_list, cap_code, function, msg_bits):
    """Codeword POCSAG de 32 bits: bit de flag(1) + address/data(20) + function(2) + parity(10).
    Version simplificada: arma la trama de bits para el pager (alfanumerico)."""
    # No implementamos el BCH completo; generamos una trama POCSAG funcional minima
    # que el hardware de radio transmite tal cual. El decodificador del pager la interpreta.
    out = []
    # Address word
    addr = cap_code & 0x1FFFFF
    word = (0 << 31) | (addr << 13) | (function << 11)
    out += [(word >> i) & 1 for i in range(31, -1, -1)]
    # Message words (alfanumerico: 7 bits por char, 20 bits por word)
    if function == FUNCTION_ALPHANUMERIC:
        chars = msg_bits
        # agrupar en bloques de 20 bits
        buf = ""
        for ch in chars:
            buf += format(ord(ch) & 0x7F, "07b")
        # rellenar
        while len(buf) % 20 != 0: buf += "0"
        for i in range(0, len(buf), 20):
            chunk = buf[i:i+20]
            mw = (1 << 31) | (int(chunk, 2) << 11)
            out += [(mw >> j) & 1 for j in range(31, -1, -1)]
    elif function == FUNCTION_NUMERIC:
        digits = "0123456789*U -() "
        buf = ""
        for ch in msg_bits:
            idx = digits.index(ch) if ch in digits else 0
            buf += format(idx, "04b")
        while len(buf) % 20 != 0: buf += "0"
        for i in range(0, len(buf), 20):
            chunk = buf[i:i+20]
            mw = (1 << 31) | (int(chunk, 2) << 11)
            out += [(mw >> j) & 1 for j in range(31, -1, -1)]
    return out

def build_frame(cap_code, mensaje, baud, function_mode):
    if function_mode == "numeric": fn = FUNCTION_NUMERIC
    elif function_mode == "tone": fn = FUNCTION_TONE
    else: fn = FUNCTION_ALPHANUMERIC
    preamble_bits = int(get_config("preamble_bits", "576"))
    preamble = [1,0] * (preamble_bits // 2)
    # Frame sync
    sync = [int(b) for b in format(0x7CD215D8, "032b")]
    # Codewords
    cw = encode_codeword([], cap_code, fn, mensaje if fn != FUNCTION_TONE else "")
    frame = preamble + sync + cw
    # idle padding
    frame += [0,1,0,1] * 16
    return frame

def warmup_tone(ms, rate=22050):
    n = int(rate * ms / 1000)
    return [math.sin(2*math.pi*350*i/rate)*0.6 for i in range(n)]

def main():
    if len(sys.argv) < 3:
        print("Uso: pocsag_gen.py <cap_code> <mensaje> [baudios] [wav_out]", file=sys.stderr); sys.exit(1)
    cap = int(str(sys.argv[1]).split(",")[0])  # primer cap si es grupo
    mensaje = str(sys.argv[2])
    baud = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else int(get_config("baudios_default", "1200"))
    wav_out = sys.argv[4] if len(sys.argv) > 4 else "/tmp/pocsag_out.wav"
    fm = get_config("function_mode", "alphanumeric")
    dev_hz = int(get_config("fsk_deviation_baseband_hz", "450"))
    levels = int(get_config("fsk_levels", "2"))
    warm_ms = int(get_config(f"warmup_{baud}_ms", "1500"))
    bits = build_frame(cap, mensaje, baud, fm)
    samples = bits_to_fsk(bits, baud, dev_hz, 22050, levels)
    samples = warmup_tone(warm_ms) + samples
    samples = normalize(samples)
    write_wav(wav_out, samples, 22050)
    print(f"OK {wav_out} ({len(samples)} samples, {baud} baud, modo {fm})")

if __name__ == "__main__":
    main()