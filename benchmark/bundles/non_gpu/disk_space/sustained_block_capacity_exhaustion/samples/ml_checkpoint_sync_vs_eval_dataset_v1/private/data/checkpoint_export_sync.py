#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time


stop_requested = False


def stop_handler(_signum, _frame):
    global stop_requested
    stop_requested = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def content_block(name):
    digest = hashlib.sha256(("checkpoint-export-v1:" + name).encode()).digest()
    return (digest * ((1024 * 1024 + len(digest) - 1) // len(digest)))[: 1024 * 1024]


def write_shard(path, size):
    block = content_block(path.name)
    digest = hashlib.sha256()
    remaining = size
    with path.open("wb", buffering=0) as handle:
        while remaining:
            piece = block[: min(len(block), remaining)]
            handle.write(piece)
            digest.update(piece)
            remaining -= len(piece)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Export and verify a resumable ML checkpoint")
    ap.add_argument("--output", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--total-bytes", required=True, type=int)
    ap.add_argument("--files", required=True, type=int)
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    output = pathlib.Path(args.output)
    runtime = pathlib.Path(args.runtime)
    output.mkdir(parents=True, exist_ok=False)
    runtime.mkdir(parents=True, exist_ok=True)

    base, extra = divmod(args.total_bytes, args.files)
    entries = []
    for index in range(args.files):
        name = (
            f"model-{index:05d}-of-{args.files:05d}.safetensors"
            if index < args.files - 1
            else "optimizer-state-00001-of-00001.bin"
        )
        size = base + (1 if index < extra else 0)
        path = output / name
        checksum = write_shard(path, size)
        stat = path.stat()
        entries.append(
            {
                "name": name,
                "size": size,
                "sha256": checksum,
                "allocated_bytes": stat.st_blocks * 512,
            }
        )

    manifest = {
        "format": "resumable-checkpoint-v1",
        "training_run": "toolmind-sft-2026-08-04",
        "epoch": 12,
        "global_step": 18400,
        "files": entries,
        "total_bytes": sum(item["size"] for item in entries),
    }
    atomic_json(output / "checkpoint_manifest.json", manifest)
    manifest_sha = hashlib.sha256((output / "checkpoint_manifest.json").read_bytes()).hexdigest()
    atomic_json(
        runtime / "ready.json",
        {
            "state": "ready",
            "manifest_sha256": manifest_sha,
            "files": len(entries),
            "total_bytes": manifest["total_bytes"],
        },
    )

    verified_bytes = 0
    passes = 0
    while not stop_requested:
        for entry in entries:
            path = output / entry["name"]
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    verified_bytes += len(chunk)
            if digest.hexdigest() != entry["sha256"]:
                atomic_json(runtime / "progress.json", {"state": "corrupt", "file": entry["name"]})
                return 3
            if stop_requested:
                break
        passes += 1
        atomic_json(
            runtime / "progress.json",
            {
                "state": "upload_verifying",
                "passes": passes,
                "verified_bytes": verified_bytes,
                "manifest_sha256": manifest_sha,
            },
        )
        time.sleep(0.1)

    atomic_json(
        runtime / "progress.json",
        {
            "state": "gracefully_stopped",
            "passes": passes,
            "verified_bytes": verified_bytes,
            "manifest_sha256": manifest_sha,
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
