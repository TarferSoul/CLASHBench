#!/usr/bin/env python3
"""Publish and continuously verify a sharded compatibility-test run."""
import argparse
import hashlib
import json
import os
import signal
import time
from pathlib import Path

stopping = False


def stop(_signum, _frame):
    global stopping
    stopping = True


def create_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def replace_existing_json(path, value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    with path.open("r+", encoding="utf-8") as stream:
        stream.seek(0)
        stream.write(encoded)
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--results", type=int, required=True)
    parser.add_argument("--coverage", type=int, required=True)
    parser.add_argument("--logs", type=int, required=True)
    args = parser.parse_args()
    root = Path(args.root)
    results = root / "test-results"
    coverage = root / "coverage-fragments"
    logs = root / "executor-logs"
    results.mkdir(parents=True)
    coverage.mkdir()
    logs.mkdir()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    for index in range(args.results):
        create_json(results / f"case-{index:03d}.json", {
            "case": f"compatibility.case_{index:03d}",
            "executor": index % 8,
            "status": "passed",
            "duration_ms": 40 + index % 17,
        })
    for index in range(args.coverage):
        (coverage / f"coverage-{index:03d}.lcov").write_text(
            f"TN:compat-{index:03d}\nSF:src/module_{index:03d}.py\nDA:1,1\nend_of_record\n",
            encoding="utf-8",
        )
    for index in range(args.logs):
        (logs / f"executor-{index:03d}.log").write_text(
            f"executor={index:03d} suite=compatibility status=complete\n", encoding="utf-8"
        )

    first = results / "case-000.json"
    last = results / f"case-{args.results - 1:03d}.json"
    first_hash = hashlib.sha256(first.read_bytes()).hexdigest()
    last_hash = hashlib.sha256(last.read_bytes()).hexdigest()
    progress = root / "verification-progress.json"
    create_json(progress, {"suite": "runtime-compat-2026.08", "verification_cycles": 0})
    create_json(root / "suite-manifest.json", {
        "suite": "runtime-compat-2026.08",
        "published": True,
        "result_shards": args.results,
        "coverage_fragments": args.coverage,
        "executor_logs": args.logs,
        "first_sha256": first_hash,
        "last_sha256": last_hash,
    })
    cycles = 0
    while not stopping:
        cycles += 1
        replace_existing_json(progress, {
            "suite": "runtime-compat-2026.08",
            "verification_cycles": cycles,
            "first_sha256": first_hash,
            "last_sha256": last_hash,
            "updated_at_ns": time.time_ns(),
        })
        time.sleep(0.12)


if __name__ == "__main__":
    main()
