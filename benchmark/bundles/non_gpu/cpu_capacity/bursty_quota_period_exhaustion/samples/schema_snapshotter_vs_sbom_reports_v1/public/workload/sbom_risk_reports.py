#!/usr/bin/env python3
"""Build deterministic per-component SBOM risk reports and an atomic manifest."""

import argparse
import hashlib
import json
import os
import pathlib
import time


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def compute_report(report_id, packages, depth, rounds, seed):
    started = time.perf_counter()
    digest = hashlib.sha256(f"report:{seed}:{report_id}".encode()).digest()
    critical = 0
    paths = 0
    for package in range(packages):
        token = digest + package.to_bytes(4, "little")
        for level in range(depth):
            token = hashlib.pbkdf2_hmac(
                "sha256", token, f"dep:{report_id}:{package}:{level}".encode(), rounds
            )
            critical += token[0] < 11
            paths += 1
        digest = hashlib.sha256(digest + token).digest()
    return {
        "schema": "sbom-risk-report-v1",
        "report_id": report_id,
        "package_count": packages,
        "dependency_paths": paths,
        "critical_findings": critical,
        "content_digest": digest.hex(),
        "elapsed_ms": round((time.perf_counter() - started) * 1000.0, 3),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--deadline-ms", type=float, default=None)
    args = parser.parse_args()
    job = json.loads(pathlib.Path(args.job).read_text())
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()
    deadline = float(args.deadline_ms if args.deadline_ms is not None else job["max_report_ms"])
    reports = []
    for report_id in range(int(job["report_count"])):
        row = compute_report(
            report_id,
            int(job["packages_per_report"]),
            int(job["dependency_depth"]),
            int(job["hash_rounds"]),
            int(job["seed"]),
        )
        atomic_json(output / f"risk-report-{report_id:02d}.json", row)
        reports.append(row)
    aggregate = hashlib.sha256()
    for row in reports:
        aggregate.update(row["content_digest"].encode())
    misses = sum(float(row["elapsed_ms"]) > deadline for row in reports)
    manifest = {
        "schema": "sbom-risk-manifest-v1",
        "report_count": len(reports),
        "expected_report_count": int(job["report_count"]),
        "complete": len(reports) == int(job["report_count"]),
        "deadline_ms": round(deadline, 3),
        "deadline_misses": misses,
        "max_latency_ms": max(float(row["elapsed_ms"]) for row in reports),
        "latencies_ms": [float(row["elapsed_ms"]) for row in reports],
        "report_digests": [row["content_digest"] for row in reports],
        "aggregate_digest": aggregate.hexdigest(),
    }
    atomic_json(output / "manifest.json", manifest)
    print(json.dumps(manifest, sort_keys=True))
    raise SystemExit(0 if manifest["complete"] and misses == 0 else 2)


if __name__ == "__main__":
    main()
