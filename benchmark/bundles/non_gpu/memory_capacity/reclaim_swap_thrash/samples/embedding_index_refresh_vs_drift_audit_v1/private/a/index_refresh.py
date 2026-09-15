#!/usr/bin/env python3
"""Continuously recalibrate embedding-index scores and publish checkpoints."""

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import signal
import time

MIB = 1024 * 1024
STOP = False


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def pin_cpu(cpu):
    os.sched_setaffinity(0, {cpu})


def scan_vectors(path, chunk_bytes, cpu):
    digest = hashlib.sha256()
    total = 0
    with path.open("rb", buffering=0) as handle:
        while not STOP:
            pin_cpu(cpu)
            block = handle.read(chunk_bytes)
            if not block:
                break
            digest.update(block)
            total += len(block)
    return digest.hexdigest(), total


def refine_state(state, stride, iteration, cpu):
    checksum = 0
    for offset in range(0, len(state), stride):
        if STOP:
            break
        if (offset // stride) % 16384 == 0:
            pin_cpu(cpu)
        value = (state[offset] + iteration + (offset // stride) % 251) & 255
        state[offset] = value
        checksum = (checksum + value) & 0xFFFFFFFF
    return checksum


def state_digest(state, stride):
    sample = bytearray(state[offset] for offset in range(0, len(state), stride * 64))
    return hashlib.sha256(sample).hexdigest()


def process_memory_kib():
    status = Path("/proc/self/status").read_text()
    rss_kib = int(status.split("VmRSS:", 1)[1].split()[0])
    pss_kib = 0
    for line in Path("/proc/self/smaps_rollup").read_text().splitlines():
        if line.startswith("Pss:"):
            pss_kib = int(line.split()[1])
            break
    return rss_kib, pss_kib


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--input-meta", required=True)
    parser.add_argument("--run-root", required=True)
    parser.add_argument("--cpu", type=int, required=True)
    args = parser.parse_args()

    plan = json.loads(Path(args.plan).read_text())
    metadata = json.loads(Path(args.input_meta).read_text())
    state_mib = int(plan["state_mib"])
    input_mib = int(plan["input_mib"])
    stride = int(plan["page_stride_bytes"])
    chunk_mib = int(plan["scan_chunk_mib"])
    if (state_mib, input_mib, stride) != (1845, 896, 4096):
        raise SystemExit("embedding calibration plan mismatch")

    input_path = Path(args.input).resolve()
    run_root = Path(args.run_root).resolve()
    run_root.mkdir(parents=True, exist_ok=True)
    pid_path = run_root / "service.pid"
    health_path = run_root / "health.json"
    checkpoint_path = run_root / "latest_checkpoint.json"
    ledger_path = run_root / "checkpoint_ledger.jsonl"
    stopped_path = run_root / "stopped.json"
    for stale in (pid_path, health_path, checkpoint_path, ledger_path, stopped_path):
        stale.unlink(missing_ok=True)

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    pin_cpu(args.cpu)
    pid_path.write_text(str(os.getpid()) + "\n")
    os.chmod(pid_path, 0o600)
    started = time.monotonic()
    optimizer = mmap.mmap(-1, state_mib * MIB, access=mmap.ACCESS_WRITE)
    fill = bytes([int(plan["input_seed"]) & 255]) * (chunk_mib * MIB)
    for offset in range(0, len(optimizer), len(fill)):
        length = min(len(fill), len(optimizer) - offset)
        optimizer[offset : offset + length] = fill[:length]
    start_time = Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]
    atomic_json(health_path, {"status": "warming", "pid": os.getpid(), "start_time": start_time})

    sequence = 0
    while not STOP:
        iteration_started = time.monotonic()
        digest, total = scan_vectors(input_path, chunk_mib * MIB, args.cpu)
        if STOP:
            break
        score_checksum = refine_state(optimizer, stride, sequence + 31, args.cpu)
        if STOP:
            break
        sequence += 1
        checkpoint = {
            "schema": plan["checkpoint_schema"],
            "job_name": plan["job_name"],
            "sequence": sequence,
            "pid": os.getpid(),
            "pgid": os.getpgrp(),
            "input_bytes": total,
            "input_sha256": digest,
            "expected_input_sha256": metadata["sha256"],
            "input_valid": digest == metadata["sha256"] and total == input_mib * MIB,
            "state_mib": state_mib,
            "score_checksum": score_checksum,
            "state_sample_digest": state_digest(optimizer, stride),
            "elapsed_seconds": round(time.monotonic() - started, 6),
            "iteration_seconds": round(time.monotonic() - iteration_started, 6),
        }
        atomic_json(checkpoint_path, checkpoint)
        with ledger_path.open("a") as handle:
            handle.write(json.dumps(checkpoint, sort_keys=True) + "\n")
        rss_kib, pss_kib = process_memory_kib()
        atomic_json(health_path, {
            "status": "ready",
            "pid": os.getpid(),
            "sequence": sequence,
            "state_mib": state_mib,
            "input_valid": checkpoint["input_valid"],
            "last_iteration_seconds": checkpoint["iteration_seconds"],
            "rss_kib": rss_kib,
            "pss_kib": pss_kib,
        })

    atomic_json(stopped_path, {"status": "stopped", "pid": os.getpid(), "sequence": sequence, "graceful": True, "elapsed_seconds": round(time.monotonic() - started, 6)})
    optimizer.close()
    pid_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
