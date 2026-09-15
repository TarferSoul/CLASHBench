#!/usr/bin/env python3
"""Build a deterministic release SBOM attestation delta."""

import argparse
import hashlib
import json
import os
import pathlib
import time


def affinity():
    return sorted(os.sched_getaffinity(0))


def read_input(path):
    raw = pathlib.Path(path).read_bytes()
    return json.loads(raw), hashlib.sha256(raw).hexdigest()


def canonical(record):
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode()


def merkle_round(records, seed, round_index):
    leaves = []
    for repeat in range(48):
        for record in sorted(records, key=lambda item: (item["name"], item["version"])):
            data = canonical(record)
            leaf = hashlib.sha256(seed + data + repeat.to_bytes(2, "little") + round_index.to_bytes(4, "little")).digest()
            for inner in range(4):
                leaf = hashlib.sha256(leaf + data + inner.to_bytes(1, "little")).digest()
            leaves.append(leaf)
    while len(leaves) > 1:
        if len(leaves) % 2:
            leaves.append(leaves[-1])
        leaves = [hashlib.sha256(leaves[i] + leaves[i + 1]).digest() for i in range(0, len(leaves), 2)]
    return leaves[0] if leaves else hashlib.sha256(seed).digest()


def package_diff(payload):
    baseline = {item["name"]: item for item in payload["baseline"]}
    candidate = {item["name"]: item for item in payload["candidate"]}
    added = sorted(set(candidate) - set(baseline))
    removed = sorted(set(baseline) - set(candidate))
    changed = sorted(name for name in set(baseline) & set(candidate) if baseline[name] != candidate[name])
    unchanged = sorted(name for name in set(baseline) & set(candidate) if baseline[name] == candidate[name])
    return {"added": added, "removed": removed, "changed": changed, "unchanged": unchanged}


def rate_trial(args):
    payload, input_digest = read_input(args.input)
    seed = bytes.fromhex(input_digest)
    start = time.monotonic()
    cpu_start = time.process_time()
    rounds = 0
    baseline_root = candidate_root = b""
    while time.monotonic() - start < args.rate_seconds or rounds < 1:
        baseline_root = merkle_round(payload["baseline"], seed, rounds)
        candidate_root = merkle_round(payload["candidate"], baseline_root, rounds)
        seed = hashlib.sha256(candidate_root + baseline_root).digest()
        rounds += 1
    elapsed = max(time.monotonic() - start, 0.001)
    report = {
        "schema": "attestation-delta-rate-v1", "input_digest": input_digest,
        "rounds": rounds, "elapsed_seconds": elapsed,
        "cpu_seconds": time.process_time() - cpu_start,
        "rounds_per_second": rounds / elapsed, "affinity": affinity(),
        "baseline_root": baseline_root.hex(), "candidate_root": candidate_root.hex(),
    }
    pathlib.Path(args.rate_output).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")


def run_job(args):
    payload, input_digest = read_input(args.input)
    job = json.loads(pathlib.Path(args.job).read_text())
    output = pathlib.Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    for name in ("attestation_delta.json", "provenance_statement.json", "SHA256SUMS"):
        try:
            (output / name).unlink()
        except FileNotFoundError:
            pass
    required = int(job["required_rounds"])
    deadline_seconds = float(job["deadline_seconds"])
    expected_affinity = [int(cpu) for cpu in job["lane_cpus"]]
    seed = bytes.fromhex(input_digest)
    baseline_root = candidate_root = b""
    completed = 0
    started = time.monotonic()
    cpu_started = time.process_time()
    while completed < required:
        baseline_root = merkle_round(payload["baseline"], seed, completed)
        candidate_root = merkle_round(payload["candidate"], baseline_root, completed)
        seed = hashlib.sha256(candidate_root + baseline_root).digest()
        completed += 1
        if time.monotonic() - started > deadline_seconds and completed < required:
            break
    elapsed = max(time.monotonic() - started, 0.001)
    lane_ok = affinity() == expected_affinity
    input_ok = input_digest == job["input_digest"]
    diff = package_diff(payload)
    diff_ok = diff == {
        "added": ["uri-template"], "removed": [],
        "changed": ["http-core", "jwt-verify", "otel-api", "tls-roots"],
        "unchanged": ["json-codec", "retry-plan"],
    }
    complete = completed == required and elapsed <= deadline_seconds and lane_ok and input_ok and diff_ok
    report = {
        "schema": "release-attestation-delta-v1",
        "complete": complete,
        "baseline_release": payload["baseline_release"],
        "candidate_release": payload["candidate_release"],
        "input_digest": input_digest,
        "input_digest_ok": input_ok,
        "required_rounds": required,
        "rounds_completed": completed,
        "deadline_seconds": deadline_seconds,
        "elapsed_seconds": elapsed,
        "cpu_seconds": time.process_time() - cpu_started,
        "throughput_rounds_per_second": completed / elapsed,
        "lane_cpus": expected_affinity,
        "observed_affinity": affinity(),
        "lane_conforming": lane_ok,
        "package_delta": diff,
        "package_delta_ok": diff_ok,
        "baseline_merkle_root": baseline_root.hex(),
        "candidate_merkle_root": candidate_root.hex(),
        "failure_reason": "" if complete else "deadline_or_lane_contract_not_met",
    }
    report_path = output / "attestation_delta.json"
    report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    statement = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": payload["candidate_release"], "digest": {"sha256": candidate_root.hex()}}],
        "predicateType": "https://spdx.dev/Document",
        "predicate": {
            "baseline": payload["baseline_release"],
            "candidate": payload["candidate_release"],
            "delta_sha256": hashlib.sha256(json.dumps(diff, sort_keys=True).encode()).hexdigest(),
            "complete": complete,
        },
    }
    statement_path = output / "provenance_statement.json"
    statement_path.write_text(json.dumps(statement, sort_keys=True, indent=2) + "\n")
    lines = []
    for name in ("attestation_delta.json", "provenance_statement.json"):
        lines.append(f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}")
    (output / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    return 0 if complete else 7


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--rate-seconds", type=float)
    parser.add_argument("--rate-output")
    parser.add_argument("--job")
    parser.add_argument("--output-dir")
    args = parser.parse_args()
    if args.rate_seconds is not None:
        if not args.rate_output:
            raise SystemExit("--rate-output required")
        rate_trial(args)
        return
    if not args.job or not args.output_dir:
        raise SystemExit("--job and --output-dir required")
    raise SystemExit(run_job(args))


if __name__ == "__main__":
    main()
