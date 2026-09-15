#!/usr/bin/env python3
"""Generate and verify a pinned credential KDF migration-vector pack."""

import argparse
import hashlib
import json
import os
import pathlib
import random
import resource
import tempfile
import time

EXPECTED_JOB = {
    "algorithm": "pbkdf2-hmac-sha256",
    "description": "Pinned credential KDF migration-vector acceptance for the reproducible security runner lane",
    "dklen": 32,
    "iterations": 120000,
    "job_name": "credential_kdf_migration_2026_08",
    "measurement_passes": 3,
    "placement_policy": "credential_migration_smt_lane_v4",
    "vector_count": 24,
}


def atomic_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
    os.replace(temporary, path)


def parse_placement(path): return dict(line.split("=", 1) for line in pathlib.Path(path).read_text().splitlines() if line)


def topology(cpu):
    root = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    return {"logical_cpu": cpu, "physical_package_id": int((root / "physical_package_id").read_text()), "core_id": int((root / "core_id").read_text()), "thread_siblings_list": (root / "thread_siblings_list").read_text().strip()}


def merkle(values):
    nodes = [hashlib.sha256(b"leaf:" + value).digest() for value in values]
    while len(nodes) > 1:
        if len(nodes) % 2: nodes.append(nodes[-1])
        nodes = [hashlib.sha256(b"node:" + nodes[index] + nodes[index + 1]).digest() for index in range(0, len(nodes), 2)]
    return nodes[0].hex()


def prepare(job, root):
    root.mkdir(parents=True, exist_ok=True); generator = random.Random(0x4B444632)
    with (root / "migration_inputs.jsonl").open("w") as handle:
        for index in range(job["vector_count"]):
            row = {"vector_id": f"migration-{index + 1:03d}", "secret_hex": generator.randbytes(24).hex(), "salt_hex": generator.randbytes(16).hex()}
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def run(job, placement, acceptance, input_root, output):
    cpu = int(placement["B_CPU"])
    if placement["PLACEMENT_POLICY_ID"] != job["placement_policy"]: raise RuntimeError("placement policy mismatch")
    os.sched_setaffinity(0, {cpu}); affinity = sorted(os.sched_getaffinity(0))
    if affinity != [cpu]: raise RuntimeError("exact assigned affinity unavailable")
    inputs = [json.loads(line) for line in (input_root / "migration_inputs.jsonl").read_text().splitlines() if line]
    if len(inputs) != job["vector_count"]: raise RuntimeError("input vector count mismatch")
    output.mkdir(parents=True, exist_ok=True)
    for path in output.iterdir():
        if path.is_file() or path.is_symlink(): path.unlink()
    usage_before = resource.getrusage(resource.RUSAGE_SELF); started_at = time.time(); started = time.perf_counter(); final_values = []
    for measurement_pass in range(job["measurement_passes"]):
        current = []
        for row in inputs:
            current.append(hashlib.pbkdf2_hmac("sha256", bytes.fromhex(row["secret_hex"]), bytes.fromhex(row["salt_hex"]), job["iterations"], dklen=job["dklen"]))
        if measurement_pass == job["measurement_passes"] - 1: final_values = current
    elapsed = time.perf_counter() - started; usage_after = resource.getrusage(resource.RUSAGE_SELF)
    cpu_seconds = usage_after.ru_utime + usage_after.ru_stime - usage_before.ru_utime - usage_before.ru_stime
    vector_operations = len(inputs) * job["measurement_passes"]; rate = vector_operations / elapsed
    with (output / "migration_vectors.jsonl").open("w") as handle:
        for row, value in zip(inputs, final_values): handle.write(json.dumps({"vector_id": row["vector_id"], "derived_key_hex": value.hex()}, sort_keys=True) + "\n")
    minimum = float(acceptance["minimum_rate_per_second"]) if acceptance else None
    report = {"job_name": job["job_name"], "algorithm": job["algorithm"], "placement_policy": job["placement_policy"], "assigned_cpu": cpu, "observed_affinity": affinity, "topology": topology(cpu), "vector_count": len(inputs), "measurement_passes": job["measurement_passes"], "vector_operations": vector_operations, "iterations": job["iterations"], "elapsed_seconds": elapsed, "cpu_seconds": cpu_seconds, "vectors_per_second": rate, "minimum_rate_per_second": minimum, "meets_acceptance": None if minimum is None else rate >= minimum, "merkle_root": merkle(final_values), "started_at": started_at, "finished_at": time.time()}
    atomic_json(output / "verification_report.json", report)
    print(f"KDF_VECTORS_OK=1 vectors={len(inputs)} cpu={cpu} vectors_per_second={rate:.6f} meets_acceptance={report['meets_acceptance']}")


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--job", required=True); parser.add_argument("--placement"); parser.add_argument("--acceptance"); parser.add_argument("--input", required=True); parser.add_argument("--output"); parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args(); job = json.loads(pathlib.Path(args.job).read_text())
    if job != EXPECTED_JOB: raise SystemExit("job recipe does not match installed migration contract")
    input_root = pathlib.Path(args.input)
    if args.prepare_only: prepare(job, input_root); print(f"KDF_INPUTS_READY=1 count={job['vector_count']}"); return
    if not args.placement or not args.output: raise SystemExit("--placement and --output are required")
    acceptance = json.loads(pathlib.Path(args.acceptance).read_text()) if args.acceptance else None
    run(job, parse_placement(args.placement), acceptance, input_root, pathlib.Path(args.output))


if __name__ == "__main__": main()
