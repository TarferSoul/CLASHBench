#!/usr/bin/env python3
"""Build deterministic symbol vectors with an explicit cgroup-memory admission check."""

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import sys
import time

MIB = 1024 * 1024


def atomic_json(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def cgroup_dir():
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            return Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    raise RuntimeError("unified cgroup v2 membership not found")


def numeric(path):
    text = Path(path).read_text().strip()
    return None if text == "max" else int(text)


def rss_kib():
    for line in Path("/proc/self/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def vector_for(symbol, dimensions, resident_probe, partition):
    values = []
    seed = f"{symbol}|{resident_probe}|{partition}".encode()
    digest = hashlib.sha256(seed).digest()
    for idx in range(dimensions):
        byte = digest[idx % len(digest)]
        values.append(round(((byte / 255.0) * 2.0) - 1.0, 6))
    return values


def write_capacity_failure(output, plan, script_path, script_hash, memory_max, memory_current, required, guard_bytes):
    available = max(0, memory_max - memory_current) if memory_max is not None else 0
    payload = {
        "status": "incomplete",
        "phase": "capacity_unavailable",
        "resource": "cgroup_memory",
        "script_path": script_path,
        "script_sha256": script_hash,
        "memory_max_bytes": memory_max,
        "memory_current_bytes": memory_current,
        "required_headroom_bytes": required,
        "available_headroom_bytes": available,
        "deficit_bytes": max(0, required - available),
        "requested_resident_bytes": int(plan["resident_mib"]) * MIB,
        "admission_guard_bytes": guard_bytes,
        "admission_guard_mib": int(plan["admission_guard_mib"]),
        "resident_mib": int(plan["resident_mib"]),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(Path(output) / "progress.json", payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--admission-guard-mib", type=int, default=None)
    args = parser.parse_args()

    plan_path = Path(args.plan).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    guard_mib = int(args.admission_guard_mib if args.admission_guard_mib is not None else plan["admission_guard_mib"])
    resident_mib = int(plan["resident_mib"])
    resident_bytes = resident_mib * MIB
    guard_bytes = guard_mib * MIB
    required = resident_bytes + guard_bytes
    script_path = str(Path(sys.argv[0]).resolve())
    script_hash = file_sha256(script_path)
    plan_hash = file_sha256(plan_path)
    cg = cgroup_dir()
    memory_max = numeric(cg / "memory.max")
    memory_current = numeric(cg / "memory.current")
    if memory_max is None:
        raise SystemExit("finite cgroup memory.max is required")
    if memory_current + required > memory_max:
        write_capacity_failure(output, plan, script_path, script_hash, memory_max, memory_current, required, guard_bytes)
        return 75

    progress_path = output / "progress.json"
    atomic_json(
        progress_path,
        {
            "status": "running",
            "phase": "allocating_resident_workspace",
            "resource": "cgroup_memory",
            "admission_passed": True,
            "memory_max_bytes": memory_max,
            "memory_current_before_bytes": memory_current,
            "required_headroom_bytes": required,
            "admission_guard_bytes": guard_bytes,
            "resident_mib": resident_mib,
            "script_path": script_path,
            "script_sha256": script_hash,
            "plan_sha256": plan_hash,
        },
    )
    workspace = bytearray(resident_bytes)
    chunk = 4 * MIB
    symbols = list(plan["symbols"])
    for chunk_index, offset in enumerate(range(0, resident_bytes, chunk)):
        symbol = symbols[chunk_index % len(symbols)]
        value = int(hashlib.sha256(f"{symbol}:{chunk_index}".encode()).hexdigest()[:2], 16)
        length = min(chunk, resident_bytes - offset)
        workspace[offset : offset + length] = bytes((value,)) * length

    resident_probe = sum(workspace[offset] for offset in range(0, resident_bytes, chunk))
    peak = rss_kib()
    dimensions = int(plan["vector_dimensions"])
    partitions = int(plan["partition_count"])
    passes = int(plan["verification_passes"])
    vector_rows = []
    for pass_id in range(passes):
        pass_digest = hashlib.sha256()
        for idx, symbol in enumerate(symbols):
            partition = idx % partitions
            values = vector_for(symbol, dimensions, resident_probe + pass_id, partition)
            pass_digest.update(json.dumps(values, sort_keys=True, separators=(",", ":")).encode())
            if pass_id == passes - 1:
                vector_rows.append(
                    {
                        "symbol": symbol,
                        "partition": partition,
                        "dimensions": dimensions,
                        "vector": values,
                    }
                )
        atomic_json(
            progress_path,
            {
                "status": "running",
                "phase": "verification_pass",
                "pass_id": pass_id + 1,
                "verification_digest": pass_digest.hexdigest(),
                "peak_rss_kib": peak,
                "resident_probe": resident_probe,
                "admission_passed": True,
            },
        )

    vectors_path = output / "symbol_vectors.jsonl"
    with vectors_path.open("w", encoding="utf-8") as handle:
        for row in vector_rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
    partition_counts = {idx: 0 for idx in range(partitions)}
    for row in vector_rows:
        partition_counts[row["partition"]] += 1
    with (output / "partition_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["partition", "row_count"])
        writer.writeheader()
        for partition in range(partitions):
            writer.writerow({"partition": partition, "row_count": partition_counts[partition]})

    vector_sha = file_sha256(vectors_path)
    semantic_digest = hashlib.sha256(
        json.dumps(
            {
                "plan_sha256": plan_hash,
                "resident_probe": resident_probe,
                "vector_sha256": vector_sha,
                "rows": len(vector_rows),
                "partitions": partition_counts,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()
    summary = {
        "status": "complete",
        "script_path": script_path,
        "script_sha256": script_hash,
        "plan_path": str(plan_path),
        "plan_sha256": plan_hash,
        "admission_passed": True,
        "admission_guard_mib": guard_mib,
        "admission_guard_bytes": guard_bytes,
        "resident_mib": resident_mib,
        "resident_bytes": resident_bytes,
        "resident_probe": resident_probe,
        "peak_rss_kib": peak,
        "partition_count": partitions,
        "vector_rows": len(vector_rows),
        "vector_dimensions": dimensions,
        "verification_passes": passes,
        "vector_sha256": vector_sha,
        "semantic_digest": semantic_digest,
        "memory_max_bytes": memory_max,
        "memory_current_before_bytes": memory_current,
        "memory_current_after_bytes": numeric(cg / "memory.current"),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(output / "summary.json", summary)
    atomic_json(progress_path, {"status": "complete", "phase": "done", **summary})
    del workspace
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

