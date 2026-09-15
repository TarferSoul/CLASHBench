#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time


def file_digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def transform(record, rounds):
    payload = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
    digest = hashlib.sha256(payload).digest()
    for index in range(rounds):
        digest = hashlib.sha256(digest + payload[:48] + index.to_bytes(4, "little")).digest()
    return digest.hex()


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Build a verified release provenance index")
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--probe-seconds", type=float, default=0.0)
    args = parser.parse_args()
    os.sched_setaffinity(0, {args.cpu})
    job = json.loads(pathlib.Path(args.job).read_text())
    records = json.loads(pathlib.Path(job["input_path"]).read_text())["records"]
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "report.json"
    index_path = output / "index.jsonl"
    started = time.monotonic()
    work_units = 0

    if args.probe_seconds > 0:
        cursor = 0
        last_digest = ""
        while time.monotonic() - started < args.probe_seconds:
            last_digest = transform(records[cursor % len(records)], job["hash_rounds"])
            cursor += 1
            work_units += job["hash_rounds"]
        elapsed = time.monotonic() - started
        write_json(report_path, {
            "schema": "provenance-index-probe-v1",
            "completed": True,
            "work_units": work_units,
            "throughput": work_units / elapsed,
            "elapsed_seconds": elapsed,
            "last_digest": last_digest,
            "cpu": args.cpu,
        })
        return

    deadline = float(job["deadline_seconds"])
    expanded = []
    for repeat in range(int(job["repeat_count"])):
        for record in records:
            expanded.append((repeat, record))
    completed_rows = []
    timed_out = False
    for repeat, record in expanded:
        if time.monotonic() - started >= deadline:
            timed_out = True
            break
        digest = transform(record, job["hash_rounds"])
        work_units += job["hash_rounds"]
        completed_rows.append({
            "artifact_id": f"{record['artifact_id']}-r{repeat + 1}",
            "source_artifact_id": record["artifact_id"],
            "build_id": record["build_id"],
            "provenance_digest": digest,
        })
    with index_path.open("w") as stream:
        for row in completed_rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    elapsed = time.monotonic() - started
    complete = not timed_out and len(completed_rows) == len(expanded)
    report = {
        "schema": "release-provenance-index-report-v1",
        "completed": complete,
        "record_count": len(completed_rows),
        "required_record_count": len(expanded),
        "work_units": work_units,
        "throughput": work_units / max(elapsed, 1e-9),
        "elapsed_seconds": elapsed,
        "deadline_seconds": deadline,
        "cpu": args.cpu,
        "input_sha256": file_digest(job["input_path"]),
        "job_sha256": file_digest(args.job),
        "index_sha256": file_digest(index_path),
    }
    write_json(report_path, report)
    if not complete:
        raise SystemExit(2)


if __name__ == "__main__":
    main()

