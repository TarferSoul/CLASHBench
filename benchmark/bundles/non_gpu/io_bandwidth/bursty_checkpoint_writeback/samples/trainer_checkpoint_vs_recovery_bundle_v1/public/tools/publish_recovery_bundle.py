#!/usr/bin/env python3
"""Publish a durable feature-index recovery bundle from a local job file."""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time


def fsync_dir(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def chunk_for(seed: str, shard: int, chunk_index: int, size: int) -> bytes:
    base = hashlib.sha256(f"{seed}:{shard}:{chunk_index}".encode("utf-8")).digest()
    return (base * ((size // len(base)) + 1))[:size]


def write_json_atomic(path: pathlib.Path, value: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    with tmp.open("rb") as handle:
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    fsync_dir(path.parent)


def wait_for_gate(path: str) -> None:
    if not path:
        return
    gate = pathlib.Path(path)
    while not gate.exists():
        time.sleep(0.02)


def write_shard(path: pathlib.Path, seed: str, shard: int, total_bytes: int, chunk_bytes: int) -> str:
    digest = hashlib.sha256()
    fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
    try:
        remaining = total_bytes
        chunk_index = 0
        while remaining > 0:
            size = min(chunk_bytes, remaining)
            data = chunk_for(seed, shard, chunk_index, size)
            os.write(fd, data)
            digest.update(data)
            remaining -= size
            chunk_index += 1
        os.fsync(fd)
    finally:
        os.close(fd)
    return digest.hexdigest()


def verify_file(path: pathlib.Path, expected: str) -> bool:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == expected


def publish(job: dict) -> dict:
    output = pathlib.Path(job["output_root"])
    shard_count = int(job["shard_count"])
    shard_bytes = int(job["shard_bytes"])
    chunk_bytes = int(job.get("chunk_bytes", 1024 * 1024))
    deadline = float(job.get("deadline_seconds", 0.0))
    require_deadline = bool(job.get("require_deadline", True))
    seed = str(job.get("seed", "feature-index-recovery"))

    wait_for_gate(str(job.get("start_gate_path", "")))
    started = time.monotonic()

    tmp = output.with_name(output.name + f".tmp.{os.getpid()}")
    if tmp.exists():
        shutil.rmtree(tmp)
    if output.exists() and job.get("clean_output", True):
        shutil.rmtree(output)
    tmp.mkdir(parents=True)
    shard_dir = tmp / "shards"
    shard_dir.mkdir()
    fsync_dir(tmp)

    shards = []
    for shard in range(shard_count):
        name = f"bundle_shard_{shard:03d}.bin"
        shard_path = shard_dir / name
        digest = write_shard(shard_path, seed, shard, shard_bytes, chunk_bytes)
        verified = verify_file(shard_path, digest)
        if not verified:
            raise RuntimeError(f"checksum verification failed for {name}")
        shards.append({"name": f"shards/{name}", "bytes": shard_bytes, "sha256": digest})

    manifest = {
        "format": "feature-index-recovery-bundle-v1",
        "seed": seed,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "shard_count": shard_count,
        "total_bytes": shard_count * shard_bytes,
        "shards": shards,
    }
    write_json_atomic(tmp / "manifest.json", manifest)
    elapsed_before_report = time.monotonic() - started
    deadline_met = not deadline or elapsed_before_report <= deadline
    report = {
        "complete": True,
        "verify_ok": True,
        "durable_publish": True,
        "deadline_seconds": deadline,
        "deadline_met": deadline_met,
        "elapsed_seconds": elapsed_before_report,
        "fsynced_shards": shard_count,
        "output_root": str(output),
        "total_bytes": shard_count * shard_bytes,
        "validated_shards": shard_count,
    }
    write_json_atomic(tmp / "publication_report.json", report)

    if output.exists():
        shutil.rmtree(output)
    os.replace(tmp, output)
    fsync_dir(output.parent)

    elapsed = time.monotonic() - started
    report["elapsed_seconds"] = elapsed
    report["deadline_met"] = not deadline or elapsed <= deadline
    write_json_atomic(output / "publication_report.json", report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    args = parser.parse_args()
    job = json.loads(pathlib.Path(args.job).read_text())
    report = publish(job)
    print(json.dumps(report, sort_keys=True))
    if bool(job.get("require_deadline", True)) and not report["deadline_met"]:
        return 124
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"publish_recovery_bundle_error={exc}", file=sys.stderr)
        raise
