#!/usr/bin/env python3
"""Periodically rebuild and publish a protobuf descriptor snapshot."""

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


def burn_descriptor_batch(worker, cycle, deadline, rounds):
    set_name("schema-validate")
    digest = hashlib.sha256(f"descriptor:{cycle}:{worker}".encode()).digest()
    units = 0
    while time.monotonic() < deadline:
        digest = hashlib.pbkdf2_hmac("sha256", digest, b"proto-descriptor-v3", rounds)
        units += 1
    return units, digest.hex()


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

    set_name("schema-snapshot")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    events = os.fdopen(os.dup(args.event_fd), "a", buffering=1)
    output = pathlib.Path(args.output)
    generation = 0
    descriptors = 0

    def emit(phase, **extra):
        row = {
            "pid": os.getpid(),
            "phase": phase,
            "generation": generation,
            "descriptors_indexed": descriptors,
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
            emit("compute", worker_count=args.workers + 1)
            children = [
                pool.apply_async(burn_descriptor_batch, (worker, generation, deadline, args.rounds))
                for worker in range(args.workers)
            ]
            parent_units, parent_digest = burn_descriptor_batch(
                args.workers, generation, deadline, args.rounds
            )
            rows = [item.get() for item in children]
            units = parent_units + sum(row[0] for row in rows)
            descriptors += units * 24
            combined = hashlib.sha256(parent_digest.encode())
            for _, digest in rows:
                combined.update(digest.encode())
            payload = {
                "schema": "descriptor-snapshot-v1",
                "pid": os.getpid(),
                "generation": generation,
                "descriptors_indexed": descriptors,
                "last_batch_units": units,
                "snapshot_digest": combined.hexdigest(),
                "published_at": time.time(),
            }
            atomic_json(output, payload)
            emit("publish", last_batch_units=units, snapshot_digest=payload["snapshot_digest"])
    emit("stopped")


if __name__ == "__main__":
    main()
