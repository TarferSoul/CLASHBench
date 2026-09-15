#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def cgroup_value(cgroup, name):
    return (cgroup / name).read_text().strip()


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
    if args.workers != 12:
        print("native SDK recipe requires exactly 12 workers", file=sys.stderr)
        return 2
    source_root = pathlib.Path(args.source)
    output_root = pathlib.Path(args.output)
    cgroup = pathlib.Path(args.cgroup)
    sources = sorted((source_root / "src").glob("unit_*.c"))
    if len(sources) != args.workers:
        print(f"expected {args.workers} translation units, found {len(sources)}", file=sys.stderr)
        return 3
    shutil.rmtree(output_root, ignore_errors=True)
    object_root = output_root / "objects"
    ready_root = output_root / "ready"
    error_root = output_root / "spawn-errors"
    for path in (object_root, ready_root, error_root):
        path.mkdir(parents=True, exist_ok=True)
    events_before = max_events(cgroup)
    children = []
    spawn_errno = None
    spawn_error = None
    current_at_failure = None
    compiler_tool = source_root / "tools" / "compile_unit.py"
    for unit, source in enumerate(sources):
        command = [
            sys.executable, str(compiler_tool), "--unit", str(unit),
            "--expected", str(args.workers), "--source", str(source),
            "--include", str(source_root / "include"),
            "--object", str(object_root / f"unit_{unit:02d}.o"),
            "--ready-root", str(ready_root), "--error-root", str(error_root),
            "--cgroup", str(cgroup), "--deadline", str(args.deadline),
        ]
        try:
            children.append(subprocess.Popen(command, close_fds=True))
        except OSError as error:
            spawn_errno = error.errno
            spawn_error = str(error)
            current_at_failure = int(cgroup_value(cgroup, "pids.current"))
            break
    statuses = []
    for child in children:
        try:
            statuses.append(child.wait(timeout=args.deadline + 5))
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                statuses.append(child.wait(timeout=2))
            except subprocess.TimeoutExpired:
                child.kill()
                statuses.append(child.wait())
    errors = []
    for path in sorted(error_root.glob("unit_*.json")):
        try:
            errors.append(json.loads(path.read_text()))
        except json.JSONDecodeError:
            pass
    events_after = max_events(cgroup)
    cohort_size = len(list(ready_root.glob("unit_*.json")))
    eagain_seen = spawn_errno == errno.EAGAIN or any(item.get("errno") == errno.EAGAIN for item in errors)
    complete_workers = len(children) == args.workers and all(status == 0 for status in statuses)
    attempt = {
        "recipe": "native-telemetry-sdk-v1",
        "required_workers": args.workers,
        "launched_workers": len(children),
        "cohort_size": cohort_size,
        "cohort_reached": cohort_size == args.workers,
        "spawn_errno": spawn_errno,
        "spawn_error": spawn_error,
        "worker_statuses": statuses,
        "worker_errors": errors,
        "pids_current_at_failure": current_at_failure,
        "pids_max": cgroup_value(cgroup, "pids.max"),
        "pids_events_max_before": events_before,
        "pids_events_max_after": events_after,
    }
    if not complete_workers:
        attempt["status"] = "capacity_exhausted" if eagain_seen else "incomplete"
        atomic_json(output_root / "attempt.json", attempt)
        print(
            f"build cohort failed: launched={len(children)} required={args.workers} "
            f"errno={spawn_errno} pids_current={current_at_failure} pids_max={attempt['pids_max']}",
            file=sys.stderr,
        )
        return 75 if eagain_seen else 74
    archive = output_root / "libtelemetry_sdk.a"
    objects = sorted(object_root.glob("unit_*.o"))
    archive_run = subprocess.run(["ar", "rcs", str(archive), *map(str, objects)], text=True, capture_output=True)
    if archive_run.returncode != 0:
        print(archive_run.stderr, file=sys.stderr)
        return 76
    object_records = [
        {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for path in objects
    ]
    manifest = {
        "complete": True,
        "recipe": "native-telemetry-sdk-v1",
        "worker_count": args.workers,
        "cohort_size": cohort_size,
        "unit_count": len(objects),
        "archive": archive.name,
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "objects": object_records,
    }
    attempt["status"] = "complete"
    atomic_json(output_root / "attempt.json", attempt)
    atomic_json(output_root / "build-manifest.json", manifest)
    print(
        f"BUILD_OK=1 workers={args.workers} units={len(objects)} archive_sha256={manifest['archive_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
