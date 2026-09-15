#!/usr/bin/env python3
import json
import math
import os
import struct
import sys
import time

PATH = sys.argv[1]
STATE = sys.argv[2]
RATE = 8000
CHUNK = 800


def wav_header(frames):
    data_bytes = frames * 2
    return b"RIFF" + struct.pack("<I", 36 + data_bytes) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16
    ) + b"data" + struct.pack("<I", data_bytes)


def write_state(seq, frames, fd):
    payload = {
        "pid": os.getpid(),
        "fd": fd,
        "seq": seq,
        "frames": frames,
        "rate": RATE,
        "updated_ns": time.time_ns(),
    }
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, STATE)


os.makedirs(os.path.dirname(PATH), exist_ok=True)
os.makedirs(os.path.dirname(STATE), exist_ok=True)
fd = os.open(PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
frames = 0
seq = 0
try:
    os.write(fd, wav_header(0))
    os.fsync(fd)
    write_state(seq, frames, fd)
    while True:
        values = [int(2800 * math.sin(2 * math.pi * 440 * (frames + i) / RATE)) for i in range(CHUNK)]
        os.write(fd, struct.pack("<" + "h" * len(values), *values))
        frames += len(values)
        seq += 1
        os.pwrite(fd, wav_header(frames), 0)
        os.fsync(fd)
        write_state(seq, frames, fd)
        time.sleep(0.12)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
