#!/usr/bin/env python3
import argparse
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import time
import xml.etree.ElementTree as ET
import zlib


def validate_unit(cases, worker_index, sequence):
    digest = hashlib.sha256()
    assertions = 0
    for repeat in range(260):
        for case in cases:
            record = {key: f"{key}-{sequence}-{repeat}" for key in case["required"]}
            if repeat % 2:
                record.update({key: worker_index for key in case["optional"]})
            canonical = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
            blob = canonical
            for level in (1, 6, 9):
                blob = zlib.compress(blob, level)
                blob = zlib.decompress(blob)
            missing = [key for key in case["required"] if key not in record]
            unknown = set(record) - set(case["required"]) - set(case["optional"])
            if missing or unknown:
                raise RuntimeError("schema regression fixture is inconsistent")
            digest.update(blob)
            assertions += len(case["required"]) + 1
    return digest.digest(), assertions


def worker(index, cpu, cases, counters, assertion_counts, digest_values, stopping):
    os.sched_setaffinity(0, {cpu})
    sequence = 0
    while not stopping.is_set():
        digest, assertions = validate_unit(cases, index, sequence)
        sequence += 1
        counters[index] = sequence
        assertion_counts[index] += assertions
        digest_values[index] = int.from_bytes(digest[:8], "big")


def write_outputs(output, spec, result):
    output.mkdir(parents=True, exist_ok=True)
    suite = ET.Element(
        "testsuite",
        name="telemetry-schema-compatibility",
        tests=str(len(spec["cases"])),
        failures="0" if result["accepted"] else "1",
        time=f"{result['elapsed_seconds']:.6f}",
    )
    for case in spec["cases"]:
        test = ET.SubElement(suite, "testcase", classname="telemetry.schema", name=case["id"])
        if not result["accepted"] and case is spec["cases"][0]:
            failure = ET.SubElement(test, "failure", message="throughput acceptance target not reached")
            failure.text = "The complete case sweep did not reach the calibrated rate."
    xml_bytes = ET.tostring(suite, encoding="utf-8", xml_declaration=True)
    (output / "junit.xml").write_bytes(xml_bytes)
    result["junit_sha256"] = hashlib.sha256(xml_bytes).hexdigest()
    (output / "summary.json").write_text(
        json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--trial-seconds", type=float)
    parser.add_argument("--report")
    args = parser.parse_args()
    source_path = pathlib.Path(args.input)
    source = source_path.read_bytes()
    spec = json.loads(source)
    job = json.loads(pathlib.Path(args.job).read_text())
    cpus = [int(value) for value in job["cpus"]]
    workers = int(job["workers"])
    if workers != len(cpus) or workers != 2:
        raise SystemExit("job must prescribe two workers on two CPUs")
    duration = float(args.trial_seconds or job["runtime_seconds"])
    context = mp.get_context("fork")
    counters = context.Array("Q", workers, lock=False)
    assertion_counts = context.Array("Q", workers, lock=False)
    digest_values = context.Array("Q", workers, lock=False)
    stopping = context.Event()
    processes = []
    started = time.monotonic()
    for index, cpu in enumerate(cpus):
        process = context.Process(
            target=worker,
            args=(index, cpu, spec["cases"], counters, assertion_counts, digest_values, stopping),
            name=f"schema-shard-{index}",
        )
        process.start()
        processes.append(process)
    worker_pids = [process.pid for process in processes]
    deadline = started + duration
    try:
        while time.monotonic() < deadline and all(process.is_alive() for process in processes):
            time.sleep(0.03)
    finally:
        stopping.set()
        for process in processes:
            process.join(timeout=3)
        for process in processes:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
    elapsed = time.monotonic() - started
    completed = int(sum(counters))
    rate = completed / elapsed if elapsed else 0.0
    minimum_rate = float(job.get("minimum_units_per_second", 0.0))
    result = {
        "schema": "telemetry-schema-regression-summary-v1",
        "accepted": rate >= minimum_rate and all(value > 0 for value in counters),
        "completed_case_sweeps": completed,
        "assertion_count": int(sum(assertion_counts)),
        "elapsed_seconds": elapsed,
        "units_per_second": rate,
        "minimum_units_per_second": minimum_rate,
        "worker_count": workers,
        "worker_pids": worker_pids,
        "worker_units": list(counters),
        "cpu_list": cpus,
        "input_sha256": hashlib.sha256(source).hexdigest(),
        "compatibility_digest": hashlib.sha256(
            ",".join(str(value) for value in digest_values).encode()
        ).hexdigest(),
        "case_ids": [case["id"] for case in spec["cases"]],
    }
    output = pathlib.Path(args.output)
    write_outputs(output, spec, result)
    if args.report:
        pathlib.Path(args.report).write_text(
            json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
    print(json.dumps({key: result[key] for key in ("accepted", "completed_case_sweeps", "units_per_second")}))
    if not args.trial_seconds and not result["accepted"]:
        raise SystemExit(4)


if __name__ == "__main__":
    main()
