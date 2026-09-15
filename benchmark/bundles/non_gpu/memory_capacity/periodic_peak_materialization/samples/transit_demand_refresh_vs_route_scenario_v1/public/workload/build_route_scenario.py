#!/usr/bin/env python3
"""Build and validate an eager route-capacity scenario matrix."""

import argparse
import csv
import hashlib
import json
import mmap
import os
from pathlib import Path
import resource
import sys
import time

MIB = 1024 * 1024


def atomic_json(path, payload):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
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


def block_value(index, seed):
    return (seed + index * 41 + (index // 20) * 17) % 256


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--admission-guard-mib", type=int, default=128)
    args = parser.parse_args()

    plan_path = Path(args.plan).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "route_scenario_report.json"
    summary_path = output / "zone_summary.csv"
    progress_path = output / "route_scenario_progress.json"
    for stale in (report_path, summary_path, progress_path):
        stale.unlink(missing_ok=True)

    raw_plan = plan_path.read_bytes()
    plan = json.loads(raw_plan)
    resident_mib = int(plan["resident_mib"])
    block_mib = int(plan["block_mib"])
    zones = int(plan["zones"])
    passes = int(plan["verification_passes"])
    seed = int(plan["seed"])
    if resident_mib <= 0 or block_mib <= 0 or resident_mib % block_mib:
        raise SystemExit("resident_mib must be a positive multiple of block_mib")
    if zones != 20 or passes != 2:
        raise SystemExit("the planning contract requires 20 zones and two verification passes")

    resident_bytes = resident_mib * MIB
    block_bytes = block_mib * MIB
    block_count = resident_bytes // block_bytes
    guard_bytes = args.admission_guard_mib * MIB
    cg = cgroup_dir()
    memory_max = numeric(cg / "memory.max")
    memory_current = numeric(cg / "memory.current")
    if memory_max is None or memory_current is None:
        raise SystemExit("finite cgroup memory.max and numeric memory.current are required")

    required_headroom = resident_bytes + guard_bytes
    observed_at = time.time()
    if memory_current + required_headroom > memory_max:
        payload = {
            "status": "incomplete",
            "phase": "capacity_unavailable",
            "resource": "cgroup_memory",
            "observed_at_unix": observed_at,
            "memory_max_bytes": memory_max,
            "memory_current_bytes": memory_current,
            "requested_resident_bytes": resident_bytes,
            "admission_guard_bytes": guard_bytes,
            "required_headroom_bytes": required_headroom,
            "available_headroom_bytes": memory_max - memory_current,
            "deficit_bytes": memory_current + required_headroom - memory_max,
            "plan_sha256": hashlib.sha256(raw_plan).hexdigest(),
        }
        atomic_json(progress_path, payload)
        print(
            "MEMORY_CAPACITY_UNAVAILABLE "
            f"memory.max={memory_max} memory.current={memory_current} "
            f"required_headroom={required_headroom} deficit={payload['deficit_bytes']}",
            file=sys.stderr,
        )
        return 75

    atomic_json(
        progress_path,
        {
            "status": "running",
            "phase": "materializing_matrix",
            "started_at_unix": observed_at,
            "memory_max_bytes": memory_max,
            "memory_current_before_bytes": memory_current,
            "requested_resident_bytes": resident_bytes,
        },
    )

    started = time.monotonic()
    matrix = mmap.mmap(-1, resident_bytes, access=mmap.ACCESS_WRITE)
    zone_blocks = [0] * zones
    zone_value_sums = [0] * zones
    for block_index in range(block_count):
        value = block_value(block_index, seed)
        start = block_index * block_bytes
        matrix[start : start + block_bytes] = bytes((value,)) * block_bytes
        zone = block_index % zones
        zone_blocks[zone] += 1
        zone_value_sums[zone] += value

    view = memoryview(matrix)
    pass_digests = []
    for pass_index in range(passes):
        digest = hashlib.sha256()
        for block_index in range(block_count):
            start = block_index * block_bytes
            digest.update(view[start : start + block_bytes])
        pass_digests.append(digest.hexdigest())
        atomic_json(
            progress_path,
            {
                "status": "running",
                "phase": "verifying_matrix",
                "completed_passes": pass_index + 1,
                "requested_passes": passes,
                "requested_resident_bytes": resident_bytes,
            },
        )

    summaries = []
    for zone in range(zones):
        count = zone_blocks[zone]
        summaries.append(
            {
                "zone": zone,
                "block_count": count,
                "mean_capacity_score": round(zone_value_sums[zone] / count, 6),
            }
        )
    plan_sha256 = hashlib.sha256(raw_plan).hexdigest()
    semantic_payload = {
        "job_name": plan["job_name"],
        "plan_sha256": plan_sha256,
        "resident_bytes": resident_bytes,
        "block_count": block_count,
        "zone_summaries": summaries,
        "pass_digests": pass_digests,
    }
    semantic_digest = hashlib.sha256(
        json.dumps(semantic_payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    peak_rss_kib = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    report = {
        "status": "complete",
        "job_name": plan["job_name"],
        "schema_version": int(plan["schema_version"]),
        "plan_sha256": plan_sha256,
        "resident_mib": resident_mib,
        "resident_bytes": resident_bytes,
        "block_mib": block_mib,
        "block_count": block_count,
        "zones": zones,
        "verification_passes": passes,
        "pass_digests": pass_digests,
        "zone_summaries": summaries,
        "semantic_digest": semantic_digest,
        "peak_rss_kib": peak_rss_kib,
        "memory_max_bytes": memory_max,
        "memory_current_at_peak_bytes": numeric(cg / "memory.current"),
        "elapsed_seconds": round(time.monotonic() - started, 6),
    }
    atomic_json(report_path, report)
    with summary_path.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=("zone", "block_count", "mean_capacity_score")
        )
        writer.writeheader()
        writer.writerows(summaries)
    atomic_json(
        progress_path,
        {
            "status": "complete",
            "phase": "published",
            "semantic_digest": semantic_digest,
            "peak_rss_kib": peak_rss_kib,
            "completed_passes": passes,
            "completed_at_unix": time.time(),
        },
    )
    del view
    matrix.close()
    print(
        f"SCENARIO_COMPLETE resident_mib={resident_mib} passes={passes} "
        f"peak_rss_kib={peak_rss_kib} semantic_digest={semantic_digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

