#!/usr/bin/env python3
"""Materialize and verify a resident dependency-embedding matrix."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import sys
import time


MIB = 1024 * 1024
PAGE = 4096


def atomic_json(path: Path, value: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def cgroup_dir() -> Path:
    rel = ""
    try:
        for line in Path("/proc/self/cgroup").read_text(encoding="utf-8").splitlines():
            fields = line.split(":")
            if len(fields) == 3 and fields[0] == "0":
                rel = fields[2].strip("/")
                break
    except OSError:
        pass
    return Path("/sys/fs/cgroup") / rel


def read_int(path: Path) -> int | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if text == "max":
        return None
    try:
        return int(text)
    except ValueError:
        return None


def cgroup_memory() -> dict:
    cg = cgroup_dir()
    return {
        "path": str(cg),
        "memory_max": read_int(cg / "memory.max"),
        "memory_current": read_int(cg / "memory.current"),
        "memory_peak": read_int(cg / "memory.peak"),
    }


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rss_kib() -> int:
    try:
        for line in Path("/proc/self/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def write_progress(out: Path, **fields: object) -> None:
    payload = {
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **fields,
    }
    atomic_json(out / "progress.json", payload)


def admission_check(plan: dict, out: Path) -> tuple[bool, dict]:
    memory = cgroup_memory()
    memory_max = memory["memory_max"]
    memory_current = memory["memory_current"]
    resident_bytes = int(plan["resident_mib"]) * MIB
    guard_bytes = int(plan["admission_guard_mib"]) * MIB
    required = resident_bytes + guard_bytes
    record = {
        "state": "admission_unknown",
        "memory": memory,
        "required_headroom": required,
        "resident_bytes": resident_bytes,
        "guard_bytes": guard_bytes,
    }
    if memory_max is None or memory_current is None:
        write_progress(out, state="admission_unknown", admission=record)
        return True, record
    available = memory_max - memory_current
    record["available_headroom"] = available
    if available >= required:
        record["state"] = "admission_passed"
        write_progress(
            out,
            state="admission_passed",
            admission=record,
        )
        return True, record
    record["state"] = "capacity_blocked"
    record["exit_reason"] = "cgroup_headroom_deficit"
    record["deficit"] = required - available
    write_progress(
        out,
        state="capacity_blocked",
        exit_reason="cgroup_headroom_deficit",
        memory=memory,
        required_headroom=required,
        available_headroom=available,
        deficit=required - available,
        admission=record,
    )
    print(
        "resident capacity check failed: "
        f"required_headroom={required} available_headroom={available}",
        file=sys.stderr,
    )
    return False, record


def touch_matrix(buf: bytearray, plan: dict, pass_no: int) -> tuple[str, list[dict]]:
    seed = int(plan["seed"]) + pass_no * 97
    partitions = int(plan["partitions"])
    pages = len(buf) // PAGE
    pages_per_partition = max(1, pages // partitions)
    digest = hashlib.sha256()
    rows: list[dict] = []
    accumulator = 0
    for page_index in range(pages):
        offset = page_index * PAGE
        value = (seed + page_index * 1315423911) & 0xFF
        buf[offset] = value
        accumulator = (accumulator + value + page_index) & 0xFFFFFFFFFFFFFFFF
        if (page_index + 1) % pages_per_partition == 0 or page_index + 1 == pages:
            partition = min(partitions - 1, page_index // pages_per_partition)
            digest.update(partition.to_bytes(2, "little"))
            digest.update(accumulator.to_bytes(8, "little"))
            rows.append(
                {
                    "partition": partition,
                    "pass": pass_no,
                    "pages_seen": page_index + 1,
                    "checksum": f"{accumulator:016x}",
                }
            )
    digest.update(str(plan["plan_id"]).encode("utf-8"))
    digest.update(str(plan["node_count"]).encode("utf-8"))
    digest.update(str(plan["feature_dimensions"]).encode("utf-8"))
    return digest.hexdigest(), rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", default="/work/dependency_graph_plan.json")
    parser.add_argument("--output-dir", default="/work/dependency_embeddings")
    args = parser.parse_args()

    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    write_progress(out, state="starting", plan_id=plan["plan_id"], pid=os.getpid())

    admitted, admission = admission_check(plan, out)
    if not admitted:
        return 75

    resident_mib = int(plan["resident_mib"])
    verification_passes = int(plan["verification_passes"])
    matrix = bytearray(resident_mib * MIB)
    peak = rss_kib()
    all_rows: list[dict] = []
    final_digest = ""
    for pass_no in range(1, verification_passes + 1):
        digest, rows = touch_matrix(matrix, plan, pass_no)
        final_digest = hashlib.sha256((final_digest + digest).encode("utf-8")).hexdigest()
        all_rows.extend(rows)
        peak = max(peak, rss_kib())
        write_progress(
            out,
            state="verifying",
            plan_id=plan["plan_id"],
            pass_no=pass_no,
            peak_rss_kib=peak,
            digest=final_digest,
        )

    partition_path = out / str(plan["partition_filename"])
    with partition_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["partition", "pass", "pages_seen", "checksum"])
        writer.writeheader()
        writer.writerows(all_rows)

    summary = {
        "complete": True,
        "plan_id": plan["plan_id"],
        "dataset": plan["dataset"],
        "resident_mib": resident_mib,
        "verification_passes": verification_passes,
        "passes_completed": verification_passes,
        "partitions": int(plan["partitions"]),
        "node_count": int(plan["node_count"]),
        "feature_dimensions": int(plan["feature_dimensions"]),
        "peak_rss_kib": peak,
        "matrix_digest": final_digest,
        "partition_rows": len(all_rows),
        "memory": cgroup_memory(),
        "admission": admission,
        "builder": {
            "path": str(Path(__file__).resolve()),
            "sha256": file_sha256(Path(__file__).resolve()),
        },
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(out / str(plan["summary_filename"]), summary)
    write_progress(
        out,
        state="complete",
        plan_id=plan["plan_id"],
        peak_rss_kib=peak,
        digest=final_digest,
        admission_state=admission.get("state"),
    )
    print(
        f"embedding matrix complete plan={plan['plan_id']} resident_mib={resident_mib} "
        f"passes={verification_passes} peak_rss_kib={peak} digest={final_digest}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
