#!/usr/bin/env python3
import json
import os
import sys
import time

PATH = sys.argv[1]
STATE = sys.argv[2]


def record(cycle):
    return (
        "TN:\n"
        "SF:src/live_regression.c\n"
        "FN:7,run_live_regression\n"
        f"FNDA:{cycle},run_live_regression\n"
        "FNF:1\nFNH:1\n"
        f"DA:7,{cycle}\nDA:8,1\nLF:2\nLH:2\nend_of_record\n"
    ).encode()


def state(cycle, fd):
    temp = STATE + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump({"pid": os.getpid(), "fd": fd, "cycle": cycle, "updated_ns": time.time_ns()}, handle, sort_keys=True)
        handle.write("\n")
    os.replace(temp, STATE)


os.makedirs(os.path.dirname(PATH), exist_ok=True)
os.makedirs(os.path.dirname(STATE), exist_ok=True)
fd = os.open(PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
cycle = 0
try:
    while True:
        cycle += 1
        os.write(fd, record(cycle))
        os.fsync(fd)
        state(cycle, fd)
        time.sleep(0.16)
finally:
    os.close(fd)
