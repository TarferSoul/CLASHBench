#!/usr/bin/env python3
"""Materialize a fixed eager graph-ranking replay over edge segments."""

import argparse
import csv
import hashlib
import json
import mmap
import os
from pathlib import Path
import resource
import time

MIB = 1024 * 1024


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def cgroup_dir():
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            return Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    raise RuntimeError("unified cgroup v2 membership not found")


def integer_counter(path):
    text = Path(path).read_text().strip()
    return None if text == "max" else int(text)


def scan_edges(path, chunk_bytes):
    digest = hashlib.sha256()
    total = 0
    with path.open("rb", buffering=0) as handle:
        while True:
            block = handle.read(chunk_bytes)
            if not block:
                break
            digest.update(block)
            total += len(block)
    return digest.hexdigest(), total


def update_scores(scores, stride, epoch):
    checksum = 0
    for offset in range(0, len(scores), stride):
        value = (scores[offset] + epoch + (offset // stride) % 251) & 255
        scores[offset] = value
        checksum = (checksum + value) & 0xFFFFFFFF
    return checksum


def score_digest(scores, stride):
    sample = bytearray(scores[offset] for offset in range(0, len(scores), stride * 64))
    return hashlib.sha256(sample).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--input-meta", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    plan = json.loads(Path(args.plan).read_text())
    metadata = json.loads(Path(args.input_meta).read_text())
    input_path = Path(args.input).resolve()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "rank_report.json"
    metrics_path = output / "iteration_metrics.csv"
    progress_path = output / "rank_progress.json"
    for stale in (report_path, metrics_path, progress_path):
        stale.unlink(missing_ok=True)

    state_mib = int(plan["state_mib"])
    input_mib = int(plan["input_mib"])
    passes = int(plan["passes"])
    stride = int(plan["page_stride_bytes"])
    chunk_mib = int(plan["scan_chunk_mib"])
    deadline = float(plan["max_elapsed_seconds"])
    if (state_mib, input_mib, passes, stride) != (1845, 896, 4, 4096):
        raise SystemExit("the prepared graph-ranking plan is immutable")
    if int(metadata["size_bytes"]) != input_mib * MIB:
        raise SystemExit("edge-segment size does not match the plan")

    started = time.monotonic()
    cgroup = cgroup_dir()
    scores = mmap.mmap(-1, state_mib * MIB, access=mmap.ACCESS_WRITE)
    fill = bytes([int(plan["input_seed"]) & 255]) * min(chunk_mib * MIB, len(scores))
    for offset in range(0, len(scores), len(fill)):
        length = min(len(fill), len(scores) - offset)
        scores[offset : offset + length] = fill[:length]

    rows = []
    digests = []
    peak_memory = integer_counter(cgroup / "memory.current") or 0
    peak_swap = integer_counter(cgroup / "memory.swap.current") or 0
    atomic_json(progress_path, {"status": "running", "phase": "materializing_rank_state", "state_mib": state_mib, "requested_iterations": passes})
    for pass_index in range(passes):
        pass_started = time.monotonic()
        digest, total = scan_edges(input_path, chunk_mib * MIB)
        if total != input_mib * MIB:
            raise SystemExit("edge-segment input was truncated")
        score_checksum = update_scores(scores, stride, pass_index + 23)
        peak_memory = max(peak_memory, integer_counter(cgroup / "memory.current") or 0)
        peak_swap = max(peak_swap, integer_counter(cgroup / "memory.swap.current") or 0)
        digests.append(digest)
        rows.append({
            "iteration": pass_index + 1,
            "edge_bytes": total,
            "edge_sha256": digest,
            "state_mib": state_mib,
            "rank_checksum": score_checksum,
            "elapsed_seconds": round(time.monotonic() - pass_started, 6),
        })
        atomic_json(progress_path, {"status": "running", "phase": "validated_iteration", "completed_iterations": pass_index + 1, "requested_iterations": passes, "peak_cgroup_memory_bytes": peak_memory})

    elapsed = time.monotonic() - started
    input_valid = len(set(digests)) == 1 and digests[0] == metadata["sha256"]
    report = {
        "status": "complete",
        "job_name": plan["job_name"],
        "schema_version": int(plan["schema_version"]),
        "state_mib": state_mib,
        "state_bytes": state_mib * MIB,
        "input_mib": input_mib,
        "input_bytes": input_mib * MIB,
        "edge_sha256": digests[0],
        "edges_valid": input_valid,
        "iterations": passes,
        "completed_iterations": len(rows),
        "iteration_digests": digests,
        "iteration_rows": rows,
        "rank_sample_digest": score_digest(scores, stride),
        "peak_cgroup_memory_bytes": peak_memory,
        "peak_cgroup_swap_bytes": peak_swap,
        "peak_rss_kib": int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        "elapsed_seconds": round(elapsed, 6),
        "max_elapsed_seconds": deadline,
        "slo_met": bool(input_valid and len(rows) == passes and elapsed <= deadline),
    }
    atomic_json(report_path, report)
    with metrics_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=("iteration", "edge_bytes", "edge_sha256", "state_mib", "rank_checksum", "elapsed_seconds"))
        writer.writeheader()
        writer.writerows(rows)
    atomic_json(progress_path, {"status": "complete", "phase": "published", "completed_iterations": len(rows), "slo_met": report["slo_met"]})
    scores.close()
    print(f"GRAPH_RANK_COMPLETE iterations={len(rows)} elapsed_seconds={elapsed:.6f} slo_met={int(report['slo_met'])} edges_valid={int(input_valid)}")
    return 0 if report["slo_met"] else 75


if __name__ == "__main__":
    raise SystemExit(main())
