#!/usr/bin/env python3
import csv
import hashlib
import os
import struct
import sys
import wave

SOURCE, DEST, MODE = sys.argv[1:4]
MARKER = b"b-voice-qa-v1"
RATE = 16000
REPEAT = 1000


def pcm_from_source():
    with open(SOURCE, newline="", encoding="utf-8") as handle:
        values = [int(row[0]) for row in csv.reader(handle) if row]
    if len(values) != 16:
        raise SystemExit(f"expected 16 input samples, got {len(values)}")
    peak = max(abs(value) for value in values)
    scaled = [max(-32768, min(32767, round(value * 12000 / peak))) for value in values]
    return struct.pack("<" + "h" * (len(scaled) * REPEAT), *(value for value in scaled for _ in range(REPEAT)))


pcm = pcm_from_source()
fmt = b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
data = b"data" + struct.pack("<I", len(pcm)) + pcm
marker_payload = b"INFO" + MARKER
marker = b"LIST" + struct.pack("<I", len(marker_payload)) + marker_payload
if len(marker_payload) % 2:
    marker += b"\0"
body = b"WAVE" + fmt + data + marker
artifact = b"RIFF" + struct.pack("<I", len(body)) + body
os.makedirs(os.path.dirname(DEST), exist_ok=True)
if MODE == "atomic":
    temporary = DEST + f".publish.{os.getpid()}"
    with open(temporary, "wb") as handle:
        handle.write(artifact)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, DEST)
elif MODE == "direct":
    with open(DEST, "wb") as handle:
        handle.write(artifact)
        handle.flush()
        os.fsync(handle.fileno())
else:
    raise SystemExit("mode must be direct or atomic")

with wave.open(DEST, "rb") as handle:
    if (handle.getnchannels(), handle.getsampwidth(), handle.getframerate(), handle.getnframes()) != (1, 2, RATE, 16000):
        raise SystemExit("published WAVE parameters are wrong")
if MARKER not in open(DEST, "rb").read():
    raise SystemExit("marker missing")
print(f"B_WAVE_OK=1 bytes={len(artifact)} sha256={hashlib.sha256(artifact).hexdigest()}")
