#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def max_events(cgroup):
    for line in (cgroup / "pids.events").read_text().splitlines():
        key, value = line.split()
        if key == "max":
            return int(value)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--cgroup", required=True)
    args = parser.parse_args()
    if args.workers != 15:
        print("frame audit recipe requires exactly 15 workers", file=sys.stderr)
        return 2
    source = pathlib.Path(args.source)
    output = pathlib.Path(args.output)
    cgroup = pathlib.Path(args.cgroup)
    inputs = sorted((source / "inputs").glob("shard_*.jsonl"))
    if len(inputs) != args.workers:
        print(f"expected {args.workers} input shards, found {len(inputs)}", file=sys.stderr)
        return 3
    import shutil
    shutil.rmtree(output, ignore_errors=True)
    ready = output / "ready"
    errors = output / "errors"
    reports = output / "reports"
    for path in (ready, errors, reports):
        path.mkdir(parents=True, exist_ok=True)
    events_before = max_events(cgroup)
    children = []
    spawn_errno = None
    spawn_error = None
    current_at_failure = None
    worker_tool = source / "tools" / "audit_worker.py"
    for shard, input_path in enumerate(inputs):
        command = [sys.executable, str(worker_tool), "--shard", str(shard),
                   "--expected", str(args.workers), "--input", str(input_path),
                   "--output", str(reports / f"shard_{shard:02d}.json"),
                   "--ready-root", str(ready), "--error-root", str(errors),
                   "--cgroup", str(cgroup), "--deadline", str(args.deadline)]
        try:
            children.append(subprocess.Popen(command, close_fds=True))
        except OSError as error:
            spawn_errno, spawn_error = error.errno, str(error)
            current_at_failure = int((cgroup / "pids.current").read_text())
            break
    statuses = []
    for child in children:
        try:
            statuses.append(child.wait(timeout=args.deadline + 5))
        except subprocess.TimeoutExpired:
            child.terminate()
            statuses.append(child.wait(timeout=2))
    worker_errors = []
    for path in sorted(errors.glob("shard_*.json")):
        try:
            worker_errors.append(json.loads(path.read_text()))
        except json.JSONDecodeError:
            pass
    events_after = max_events(cgroup)
    cohort_size = len(list(ready.glob("shard_*.json")))
    eagain_seen = spawn_errno == errno.EAGAIN or any(item.get("errno") == errno.EAGAIN for item in worker_errors)
    complete = len(children) == args.workers and all(status == 0 for status in statuses)
    attempt = {"recipe": "frame-audit-v1", "required_workers": args.workers,
               "launched_workers": len(children), "cohort_size": cohort_size,
               "cohort_reached": cohort_size == args.workers, "spawn_errno": spawn_errno,
               "spawn_error": spawn_error, "worker_statuses": statuses,
               "worker_errors": worker_errors, "pids_current_at_failure": current_at_failure,
               "pids_max": (cgroup / "pids.max").read_text().strip(),
               "pids_events_max_before": events_before, "pids_events_max_after": events_after}
    if not complete:
        attempt["status"] = "capacity_exhausted" if eagain_seen else "incomplete"
        atomic_json(output / "attempt.json", attempt)
        print(f"audit cohort failed: launched={len(children)} required={args.workers} errno={spawn_errno}", file=sys.stderr)
        return 75 if eagain_seen else 74
    report = output / "frame-audit-report.json"
    entries = sorted(reports.glob("shard_*.json"))
    report.write_text(json.dumps({"complete": True, "shards": [json.loads(p.read_text()) for p in entries]}, sort_keys=True, indent=2) + "\n")
    manifest = {"complete": True, "recipe": "frame-audit-v1", "worker_count": args.workers,
                "cohort_size": cohort_size, "shard_count": len(entries), "report": report.name,
                "report_sha256": hashlib.sha256(report.read_bytes()).hexdigest()}
    attempt["status"] = "complete"
    atomic_json(output / "attempt.json", attempt)
    atomic_json(output / "audit-manifest.json", manifest)
    print(f"AUDIT_OK=1 workers={args.workers} shards={len(entries)} report_sha256={manifest['report_sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
