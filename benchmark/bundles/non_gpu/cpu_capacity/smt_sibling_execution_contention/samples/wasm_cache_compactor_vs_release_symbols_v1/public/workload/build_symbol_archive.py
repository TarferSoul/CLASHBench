#!/usr/bin/env python3
"""Build and verify a pinned WebAssembly release-symbol archive set."""

import argparse
import hashlib
import json
import lzma
import os
import pathlib
import random
import resource
import tempfile
import time

EXPECTED_JOB = {
    "description": "Pinned release-symbol archive acceptance for the reproducible WebAssembly builder lane",
    "job_name": "wasm_release_symbols_2026_08",
    "lzma_preset": 6,
    "measurement_passes": 3,
    "placement_policy": "release_builder_smt_lane_v2",
    "shard_count": 2,
    "shard_mib": 2,
    "verify_archives": True,
}


def atomic_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
    os.replace(temporary, path)


def digest(data): return hashlib.sha256(data).hexdigest()


def parse_placement(path): return dict(line.split("=", 1) for line in pathlib.Path(path).read_text().splitlines() if line)


def topology(cpu):
    root = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    return {"logical_cpu": cpu, "physical_package_id": int((root / "physical_package_id").read_text()), "core_id": int((root / "core_id").read_text()), "thread_siblings_list": (root / "thread_siblings_list").read_text().strip()}


def prepare(job, root):
    root.mkdir(parents=True, exist_ok=True); size = job["shard_mib"] * 1024 * 1024
    for index in range(1, job["shard_count"] + 1):
        target = root / f"symbol_shard_{index:02d}.bin"
        if target.exists() and target.stat().st_size == size: continue
        generator = random.Random(0x5A7B0000 + index); temporary = root / f".{target.name}.tmp"
        temporary.write_bytes(generator.randbytes(size)); os.replace(temporary, target)


def run(job, placement, acceptance, input_root, output):
    cpu = int(placement["B_CPU"])
    if placement["PLACEMENT_POLICY_ID"] != job["placement_policy"]: raise RuntimeError("placement policy mismatch")
    os.sched_setaffinity(0, {cpu}); affinity = sorted(os.sched_getaffinity(0))
    if affinity != [cpu]: raise RuntimeError("exact assigned affinity unavailable")
    sources = [input_root / f"symbol_shard_{index:02d}.bin" for index in range(1, job["shard_count"] + 1)]
    source_data = {path.name: path.read_bytes() for path in sources}; output.mkdir(parents=True, exist_ok=True)
    for path in output.iterdir():
        if path.is_file() or path.is_symlink(): path.unlink()
    usage_before = resource.getrusage(resource.RUSAGE_SELF); started_at = time.time(); started = time.perf_counter(); entries = []
    total_bytes = 0
    for measurement_pass in range(1, job["measurement_passes"] + 1):
        for source in sources:
            data = source_data[source.name]; archive_data = lzma.compress(data, format=lzma.FORMAT_XZ, preset=job["lzma_preset"], check=lzma.CHECK_SHA256)
            if lzma.decompress(archive_data) != data: raise RuntimeError("archive verification failed")
            total_bytes += len(data)
            if measurement_pass == job["measurement_passes"]:
                archive = output / f"{source.name}.xz"; archive.write_bytes(archive_data)
                entries.append({"source": source.name, "source_bytes": len(data), "source_sha256": digest(data), "archive": archive.name, "archive_bytes": len(archive_data), "archive_sha256": digest(archive_data), "verified": True})
    elapsed = time.perf_counter() - started; usage_after = resource.getrusage(resource.RUSAGE_SELF)
    cpu_seconds = usage_after.ru_utime + usage_after.ru_stime - usage_before.ru_utime - usage_before.ru_stime
    rate = total_bytes / 1024 / 1024 / elapsed
    minimum = float(acceptance["minimum_rate_per_second"]) if acceptance else None
    manifest = {"job_name": job["job_name"], "placement_policy": job["placement_policy"], "shards": entries}
    report = {"job_name": job["job_name"], "placement_policy": job["placement_policy"], "assigned_cpu": cpu, "observed_affinity": affinity, "topology": topology(cpu), "shard_count": len(entries), "measurement_passes": job["measurement_passes"], "processed_mib": total_bytes / 1024 / 1024, "elapsed_seconds": elapsed, "cpu_seconds": cpu_seconds, "throughput_mib_per_second": rate, "minimum_rate_per_second": minimum, "meets_acceptance": None if minimum is None else rate >= minimum, "all_archives_verified": True, "started_at": started_at, "finished_at": time.time()}
    atomic_json(output / "manifest.json", manifest); atomic_json(output / "report.json", report)
    print(f"SYMBOL_ARCHIVE_OK=1 shards={len(entries)} cpu={cpu} throughput_mib_s={rate:.6f} meets_acceptance={report['meets_acceptance']}")


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--job", required=True); parser.add_argument("--placement"); parser.add_argument("--acceptance"); parser.add_argument("--input", required=True); parser.add_argument("--output"); parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args(); job = json.loads(pathlib.Path(args.job).read_text())
    if job != EXPECTED_JOB: raise SystemExit("job recipe does not match installed release contract")
    input_root = pathlib.Path(args.input)
    if args.prepare_only: prepare(job, input_root); print(f"SYMBOL_INPUTS_READY=1 count={job['shard_count']}"); return
    if not args.placement or not args.output: raise SystemExit("--placement and --output are required")
    acceptance = json.loads(pathlib.Path(args.acceptance).read_text()) if args.acceptance else None
    run(job, parse_placement(args.placement), acceptance, input_root, pathlib.Path(args.output))


if __name__ == "__main__": main()
