#!/usr/bin/env python3
"""Build and validate a durable incident-evidence pack with direct I/O."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


MIB = 1024 * 1024


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, path)
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def run_checked(command):
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed rc={completed.returncode}: {' '.join(command)}\n"
            f"stdout={completed.stdout[-1000:]}\nstderr={completed.stderr[-1000:]}"
        )


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb", buffering=0) as handle:
        while True:
            chunk = handle.read(4 * MIB)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--input-root", required=True)
    parser.add_argument("--output-root", required=True)
    args = parser.parse_args()

    job = json.loads(Path(args.job).read_text(encoding="utf-8"))
    part_count = int(job["part_count"])
    part_mib = int(job["part_mib"])
    block_mib = int(job["block_mib"])
    deadline = float(job["completion_window_seconds"])
    if not job.get("require_direct_io") or not job.get("require_full_range_validation"):
        raise SystemExit("job must require direct I/O and full range validation")
    if part_mib % block_mib:
        raise SystemExit("part size must be aligned to the direct-I/O block size")

    input_root = Path(args.input_root).resolve()
    output_root = Path(args.output_root).resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    parts = [input_root / f"incident_extent_{index:02d}.bin" for index in range(1, part_count + 1)]
    expected_part_bytes = part_mib * MIB
    for part in parts:
        if not part.is_file() or part.stat().st_size != expected_part_bytes:
            raise SystemExit(f"invalid input extent: {part}")

    pack = output_root / "incident_evidence.pack"
    temporary_pack = output_root / f".incident_evidence.pack.tmp.{os.getpid()}"
    progress = output_root / "repack_progress.json"
    total_bytes = expected_part_bytes * part_count
    block_bytes = block_mib * MIB
    blocks_per_part = expected_part_bytes // block_bytes
    started = time.monotonic()
    try:
        with temporary_pack.open("wb") as handle:
            handle.truncate(total_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        for index, part in enumerate(parts):
            atomic_json(progress, {
                "phase": "copying",
                "completed_parts": index,
                "bytes_published": index * expected_part_bytes,
                "elapsed_seconds": time.monotonic() - started,
            })
            run_checked([
                "dd", f"if={part}", f"of={temporary_pack}", f"bs={block_bytes}",
                "iflag=direct", "oflag=direct", "conv=notrunc",
                f"count={blocks_per_part}", f"seek={index * blocks_per_part}", "status=none",
            ])

        pack_fd = os.open(temporary_pack, os.O_RDONLY)
        try:
            os.fsync(pack_fd)
        finally:
            os.close(pack_fd)

        extents = []
        for index, part in enumerate(parts):
            offset = index * expected_part_bytes
            atomic_json(progress, {
                "phase": "validating",
                "completed_parts": part_count,
                "validated_parts": index,
                "bytes_published": total_bytes,
                "elapsed_seconds": time.monotonic() - started,
            })
            run_checked([
                "cmp", "--silent", f"--bytes={expected_part_bytes}",
                f"--ignore-initial=0:{offset}", str(part), str(temporary_pack),
            ])
            extents.append({
                "name": part.name,
                "offset": offset,
                "bytes": expected_part_bytes,
                "full_range_validated": True,
            })

        pack_digest = sha256(temporary_pack)
        os.replace(temporary_pack, pack)
        directory_fd = os.open(output_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        manifest = {
            "job_name": job["job_name"],
            "pack": pack.name,
            "pack_bytes": total_bytes,
            "pack_sha256": pack_digest,
            "extents": extents,
        }
        atomic_json(output_root / "extent_manifest.json", manifest)
        sha_path = output_root / "incident_evidence.sha256"
        sha_temp = output_root / f".{sha_path.name}.tmp.{os.getpid()}"
        with sha_temp.open("w", encoding="ascii") as handle:
            handle.write(f"{pack_digest}  {pack.name}\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(sha_temp, sha_path)
        directory_fd = os.open(output_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)

        elapsed = time.monotonic() - started
        report = {
            "job_name": job["job_name"],
            "complete": True,
            "part_count": part_count,
            "validated_parts": part_count,
            "bytes_published": total_bytes,
            "direct_io": True,
            "full_range_validation": True,
            "sha256_manifest": True,
            "durable_publish": True,
            "elapsed_seconds": elapsed,
            "completion_window_seconds": deadline,
            "completion_window_met": elapsed <= deadline,
            "pack_sha256": pack_digest,
        }
        atomic_json(output_root / "repack_report.json", report)
        atomic_json(progress, {
            "phase": "published",
            "completed_parts": part_count,
            "validated_parts": part_count,
            "bytes_published": total_bytes,
            "elapsed_seconds": elapsed,
        })
        print(json.dumps(report, sort_keys=True))
        return 0 if report["completion_window_met"] else 75
    finally:
        try:
            temporary_pack.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    sys.exit(main())
