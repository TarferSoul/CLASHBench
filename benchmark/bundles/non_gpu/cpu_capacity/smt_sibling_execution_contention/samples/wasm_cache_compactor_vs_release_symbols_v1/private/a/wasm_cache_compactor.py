#!/usr/bin/env python3
"""Continuously compact and verify WebAssembly source-map cache entries."""

import argparse
import hashlib
import json
import lzma
import os
import pathlib
import random
import signal
import tempfile
import time

running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
    os.replace(temporary, path)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(root):
    root.mkdir(parents=True, exist_ok=True)
    target = root / "source_map_cache.bin"
    expected = 4 * 1024 * 1024
    if target.exists() and target.stat().st_size == expected:
        return
    generator = random.Random(0x57A5CACE)
    temporary = root / ".source_map_cache.tmp"
    temporary.write_bytes(generator.randbytes(expected)); os.replace(temporary, target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root")
    parser.add_argument("--input-root", required=True)
    parser.add_argument("--artifact-root")
    parser.add_argument("--work-factor", type=int, default=6)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    input_root = pathlib.Path(args.input_root); prepare(input_root)
    if args.prepare_only:
        print("CACHE_INPUT_READY=1 bytes=4194304"); return
    if not args.state_root or not args.artifact_root:
        raise SystemExit("--state-root and --artifact-root are required")
    state_root, artifact_root = pathlib.Path(args.state_root), pathlib.Path(args.artifact_root)
    state_root.mkdir(parents=True, exist_ok=True); artifact_root.mkdir(parents=True, exist_ok=True)
    ledger = state_root / "unit_ledger.jsonl"; ledger.write_text("")
    source = (input_root / "source_map_cache.bin").read_bytes(); source_sha = digest(source)
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    unit = 0
    while running:
        unit += 1
        atomic_json(state_root / "status.json", {"pid": os.getpid(), "unit": unit, "phase": "compacting", "affinity": sorted(os.sched_getaffinity(0)), "updated_at": time.time()})
        started = time.perf_counter()
        archive_data = lzma.compress(source, format=lzma.FORMAT_XZ, preset=args.work_factor, check=lzma.CHECK_SHA256)
        if lzma.decompress(archive_data) != source:
            raise RuntimeError("cache archive verification failed")
        if not running:
            break
        name = f"source_map_cache_slot_{unit % 4}.xz"; target = artifact_root / name; temporary = artifact_root / f".{name}.tmp"
        temporary.write_bytes(archive_data); os.replace(temporary, target)
        entry = {"unit": unit, "artifact": name, "artifact_sha256": digest(archive_data), "source_sha256": source_sha, "source_bytes": len(source), "elapsed_seconds": time.perf_counter() - started, "completed_at": time.time()}
        with ledger.open("a") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n"); handle.flush(); os.fsync(handle.fileno())
        atomic_json(state_root / "status.json", {"pid": os.getpid(), "unit": unit, "phase": "published", "artifact": name, "affinity": sorted(os.sched_getaffinity(0)), "updated_at": time.time()})


if __name__ == "__main__":
    main()
