#!/usr/bin/env python3
"""Periodically merge CI coverage shards and publish a generation ledger."""

import argparse
import ctypes
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import signal
import time


STOP = False


def set_name(name):
    try:
        ctypes.CDLL(None).prctl(15, name.encode()[:15], 0, 0, 0)
    except Exception:
        pass


def stop(_signum, _frame):
    global STOP
    STOP = True


def merge_shards(worker, generation, deadline, rounds):
    set_name("coverage-merge")
    block = hashlib.blake2b(f"coverage:{generation}:{worker}".encode(), digest_size=64).digest()
    units = 0
    bits = 0
    while time.monotonic() < deadline:
        for index in range(rounds // 200):
            block = hashlib.blake2b(block + index.to_bytes(4, "little"), digest_size=64).digest()
            bits ^= int.from_bytes(block[:8], "little")
        units += 1
    return units, bits, block.hex()


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-fd", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--compute-seconds", type=float, required=True)
    parser.add_argument("--quiet-seconds", type=float, required=True)
    parser.add_argument("--rounds", type=int, required=True)
    args = parser.parse_args()

    set_name("coverage-ledger")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    events = os.fdopen(os.dup(args.event_fd), "a", buffering=1)
    generation = 0
    merged_lines = 0

    def emit(phase, **extra):
        row = {
            "pid": os.getpid(),
            "phase": phase,
            "generation": generation,
            "merged_lines": merged_lines,
            "time": time.time(),
        }
        row.update(extra)
        events.write(json.dumps(row, sort_keys=True) + "\n")

    emit("ready")
    context = mp.get_context("fork")
    with context.Pool(args.workers) as pool:
        while not STOP:
            emit("ingest")
            until = time.monotonic() + args.quiet_seconds
            while not STOP and time.monotonic() < until:
                time.sleep(0.03)
            if STOP:
                break

            generation += 1
            deadline = time.monotonic() + args.compute_seconds
            emit("compute", shard_workers=args.workers + 1)
            children = [
                pool.apply_async(merge_shards, (worker, generation, deadline, args.rounds))
                for worker in range(args.workers)
            ]
            parent = merge_shards(args.workers, generation, deadline, args.rounds)
            rows = [item.get() for item in children]
            all_rows = [parent] + rows
            units = sum(row[0] for row in all_rows)
            merged_lines += units * 512
            digest = hashlib.sha256()
            bitmap_fold = 0
            for _, bits, block in all_rows:
                bitmap_fold ^= bits
                digest.update(block.encode())
            payload = {
                "schema": "coverage-merge-ledger-v1",
                "pid": os.getpid(),
                "generation": generation,
                "merged_lines": merged_lines,
                "last_shard_units": units,
                "bitmap_fold": bitmap_fold,
                "coverage_digest": digest.hexdigest(),
                "published_at": time.time(),
            }
            atomic_json(args.output, payload)
            emit("publish", last_shard_units=units, coverage_digest=payload["coverage_digest"])
    emit("stopped")


if __name__ == "__main__":
    main()
