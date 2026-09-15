#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import pathlib
import time


def file_digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def build_vector(seed, dimensions):
    return [math.sin(seed * (index + 1) * 0.017) + math.cos((seed + 3) * (index + 1) * 0.011) for index in range(dimensions)]


def quantize(seed, dimensions, rounds):
    vector = build_vector(seed, dimensions)
    scale = 1.0
    accumulator = 0.0
    for round_index in range(rounds):
        cursor = round_index % dimensions
        value = math.tanh(vector[cursor] * scale + accumulator * 0.00001)
        accumulator += value * (cursor + 1)
        scale = 0.75 + abs(math.sin(accumulator * 0.000001))
        vector[cursor] = value
    peak = max(abs(value) for value in vector) or 1.0
    quantized = [max(-127, min(127, int(round(value / peak * 127)))) for value in vector]
    return quantized, peak, accumulator


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Quantize a deterministic embedding catalog")
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--probe-seconds", type=float, default=0.0)
    args = parser.parse_args()
    os.sched_setaffinity(0, {args.cpu})
    job = json.loads(pathlib.Path(args.job).read_text())
    seeds = json.loads(pathlib.Path(job["input_path"]).read_text())["seeds"]
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "report.json"
    catalog_path = output / "catalog.jsonl"
    started = time.monotonic()
    work_units = 0

    if args.probe_seconds > 0:
        cursor = 0
        last_accumulator = 0.0
        while time.monotonic() - started < args.probe_seconds:
            _, _, last_accumulator = quantize(seeds[cursor % len(seeds)], job["dimensions"], job["optimization_rounds"])
            cursor += 1
            work_units += job["dimensions"] * job["optimization_rounds"]
        elapsed = time.monotonic() - started
        write_json(report_path, {
            "schema": "embedding-quantization-probe-v1",
            "completed": True,
            "work_units": work_units,
            "throughput": work_units / elapsed,
            "elapsed_seconds": elapsed,
            "last_accumulator": last_accumulator,
            "cpu": args.cpu,
        })
        return

    expanded = [(repeat, seed) for repeat in range(job["repeat_count"]) for seed in seeds]
    deadline = float(job["deadline_seconds"])
    rows = []
    for repeat, seed in expanded:
        if time.monotonic() - started >= deadline:
            break
        vector, scale, accumulator = quantize(seed, job["dimensions"], job["optimization_rounds"])
        work_units += job["dimensions"] * job["optimization_rounds"]
        rows.append({
            "embedding_id": f"embedding-{seed}-r{repeat + 1}",
            "seed": seed,
            "dimensions": job["dimensions"],
            "scale": scale,
            "accumulator": accumulator,
            "values": vector,
        })
    with catalog_path.open("w") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    elapsed = time.monotonic() - started
    complete = len(rows) == len(expanded)
    write_json(report_path, {
        "schema": "quantized-embedding-catalog-report-v1",
        "completed": complete,
        "vector_count": len(rows),
        "required_vector_count": len(expanded),
        "dimensions": job["dimensions"],
        "work_units": work_units,
        "throughput": work_units / max(elapsed, 1e-9),
        "elapsed_seconds": elapsed,
        "deadline_seconds": deadline,
        "cpu": args.cpu,
        "input_sha256": file_digest(job["input_path"]),
        "job_sha256": file_digest(args.job),
        "catalog_sha256": file_digest(catalog_path),
    })
    if not complete:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

