#!/usr/bin/env python3
"""Continuous deterministic firmware compatibility regression service."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import time

MASK = (1 << 64) - 1
STOP = False


def stop(_signum, _frame):
    global STOP
    STOP = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def start_ticks():
    return pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]


def regression_chunk(seed, cycle):
    state = (seed ^ (cycle * 0xD6E8FEB86659FD93)) & MASK
    covered = 0
    for firmware in range(9):
        regs = [(state + firmware + index * 17) & MASK for index in range(16)]
        memory = [0] * 128
        for step in range(2200):
            op = (step + firmware + cycle) % 7
            left = step & 15
            right = (step * 5 + firmware) & 15
            if op == 0:
                regs[left] = (regs[left] + regs[right] + step) & MASK
            elif op == 1:
                regs[left] ^= (regs[right] * 0x100000001B3) & MASK
            elif op == 2:
                regs[left] = (regs[left] * ((step | 1) & 0xFFFF)) & MASK
            elif op == 3:
                memory[step & 127] = regs[left]
            elif op == 4:
                regs[left] ^= memory[(step * 3) & 127]
            elif op == 5:
                shift = step & 63
                regs[left] = ((regs[left] << shift) | (regs[left] >> (64 - shift))) & MASK
            else:
                regs[left] = (regs[left] - regs[right] - firmware) & MASK
            state ^= regs[left]
            covered |= 1 << op
    digest = hashlib.sha256(state.to_bytes(8, "little") + covered.to_bytes(2, "little")).hexdigest()
    return int(digest[:16], 16), covered, digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    root = pathlib.Path(args.state_root)
    root.mkdir(parents=True, exist_ok=True)
    state_path = root / "state.json"
    ledger = root / "cycles.jsonl"
    ledger.write_text("")
    pid = os.getpid()
    cycle = 0
    instructions = 0
    seed = 0x1234ABCD55AA7711
    while not STOP:
        cycle += 1
        seed, coverage, digest = regression_chunk(seed, cycle)
        instructions += 9 * 2200
        record = {
            "schema": "firmware-regression-state-v1",
            "pid": pid,
            "pgid": os.getpgrp(),
            "start_ticks": start_ticks(),
            "affinity": sorted(os.sched_getaffinity(0)),
            "cycle": cycle,
            "instructions_interpreted": instructions,
            "coverage_mask": coverage,
            "last_digest": digest,
            "updated_at": time.time(),
            "phase": "compatibility_sweep",
        }
        atomic_json(state_path, record)
        with ledger.open("a") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
    record["phase"] = "stopped"
    record["updated_at"] = time.time()
    atomic_json(state_path, record)


if __name__ == "__main__":
    main()
