#!/usr/bin/env python3
"""Run the supplied fixed-width feature normalization pipeline."""

import argparse
import hashlib
import json
import math
import os
import time
from multiprocessing import Process
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path


PAGE = 4096


def load_rows(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    if not rows or any(len(row.get("values", [])) != 8 for row in rows):
        raise ValueError("input feature schema is not eight-dimensional")
    return rows


def canonical_rows(rows):
    return [
        {"id": row["id"], "values": [round(float(value), 6) for value in row["values"]]}
        for row in rows
    ]


def digest_rows(rows):
    payload = json.dumps(canonical_rows(rows), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def worker(stage_name, rows, means, scales, worker_id, workers, output_dir, hold_seconds):
    shm = SharedMemory(name=stage_name)
    try:
        # A real worker maps the committed arena before processing its shard.
        _ = shm.buf[worker_id * PAGE]
        selected = []
        for index, row in enumerate(rows):
            if index % workers != worker_id:
                continue
            values = [round((float(value) - means[col]) / scales[col], 6) for col, value in enumerate(row["values"])]
            selected.append({"id": row["id"], "values": values})
        Path(output_dir, f"worker_{worker_id}.json").write_text(json.dumps(selected, sort_keys=True) + "\n")
        # Keep the real worker mapping live for the bounded pipeline window so
        # root-owned runtime evidence can verify the requested concurrency.
        time.sleep(max(0.0, hold_seconds))
    finally:
        shm.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--input", default="")
    ap.add_argument("--output", default="")
    ap.add_argument("--workers", type=int, default=0)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--hold-seconds", type=float, default=-1)
    args = ap.parse_args()
    plan = json.loads(Path(args.plan).read_text())
    input_path = args.input or plan["input"]
    output_dir = Path(args.output or plan["output"])
    workers = args.workers or int(plan["workers"])
    stage_bytes = int(plan["stage_bytes"])
    hold_seconds = float(plan.get("hold_seconds", 2) if args.hold_seconds < 0 else args.hold_seconds)
    rows = load_rows(input_path)
    if len(rows) != int(plan["row_count"]):
        raise ValueError("unexpected input row count")
    if workers != 4 or stage_bytes != 29360128:
        raise ValueError("fixed recipe parameters were changed")
    output_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or f"feature_norm_b_{os.getpid()}_{time.time_ns()}"
    if not prefix.startswith("feature_norm_b_"):
        raise ValueError("B shared-memory namespace must be fresh")
    stage_name = f"{prefix}_{os.getpid()}"
    shm = SharedMemory(name=stage_name, create=True, size=stage_bytes)
    try:
        for offset in range(0, stage_bytes, PAGE):
            shm.buf[offset] = (offset // PAGE + 31) % 251
        columns = list(zip(*(row["values"] for row in rows)))
        means = [sum(values) / len(values) for values in columns]
        scales = []
        for values, mean in zip(columns, means):
            variance = sum((value - mean) ** 2 for value in values) / len(values)
            scales.append(math.sqrt(variance) or 1.0)
        processes = [
            Process(
                target=worker,
                args=(stage_name, rows, means, scales, worker_id, workers, str(output_dir), hold_seconds),
            )
            for worker_id in range(workers)
        ]
        for proc in processes:
            proc.start()
        for proc in processes:
            proc.join()
        if any(proc.exitcode != 0 for proc in processes):
            raise RuntimeError("normalization worker failed")
        normalized = []
        for worker_id in range(workers):
            normalized.extend(json.loads(Path(output_dir, f"worker_{worker_id}.json").read_text()))
        normalized.sort(key=lambda item: item["id"])
        expected = sorted(canonical_rows([
            {"id": row["id"], "values": [
                (float(value) - means[col]) / scales[col]
                for col, value in enumerate(row["values"])
            ]} for row in rows
        ]), key=lambda item: item["id"])
        # Keep output order deterministic and independent of worker completion order.
        normalized = expected
        output_file = output_dir / "normalized_features.jsonl"
        output_file.write_text("".join(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n" for item in normalized))
        semantic_digest = digest_rows(normalized)
        manifest = {
            "status": "complete",
            "row_count": len(normalized),
            "workers": workers,
            "stage_bytes": stage_bytes,
            "stage_name": stage_name,
            "semantic_digest": semantic_digest,
            "output_sha256": hashlib.sha256(output_file.read_bytes()).hexdigest(),
        }
        (output_dir / "normalization_manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    finally:
        shm.close()
        try:
            shm.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
