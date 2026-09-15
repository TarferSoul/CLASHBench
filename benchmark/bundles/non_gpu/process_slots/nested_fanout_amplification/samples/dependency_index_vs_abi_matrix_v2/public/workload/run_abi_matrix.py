#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def atomic_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--compilers-per-worker", type=int, required=True)
    args = parser.parse_args()

    input_root = Path(args.input).resolve()
    output_root = Path(args.output).resolve()
    if args.workers <= 0 or args.compilers_per_worker <= 0:
        raise SystemExit("worker counts must be positive")
    # The sandbox prepares the agent-owned output directory before the task.
    # Clear its prior contents while retaining that writable directory.
    output_root.mkdir(parents=True, exist_ok=True)
    for child in list(output_root.iterdir()):
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    run_dir = output_root / f".abi-run-{os.getpid()}"
    run_dir.mkdir()
    gate = run_dir / "compiler-stage.open"
    fanout_gate = run_dir / "compiler-fanout.open"
    release = run_dir / "compiler-stage.close"
    worker_program = Path(__file__).with_name("abi_package_worker.py")

    children = []
    controller_errors = []
    for package in range(args.workers):
        try:
            proc = subprocess.Popen(
                [
                    sys.executable,
                    str(worker_program),
                    "--input",
                    str(input_root),
                    "--output",
                    str(output_root),
                    "--run-dir",
                    str(run_dir),
                    "--gate",
                    str(gate),
                    "--fanout-gate",
                    str(fanout_gate),
                    "--release",
                    str(release),
                    "--package",
                    str(package),
                    "--compilers",
                    str(args.compilers_per_worker),
                ]
            )
            children.append((package, proc))
        except OSError as exc:
            item = {"package": package, "errno": exc.errno, "error": str(exc), "operation": "spawn_package_worker"}
            controller_errors.append(item)
            atomic_json(run_dir / f"spawn-error-controller-{package:02d}.json", item)

    ready_deadline = time.monotonic() + 8
    while time.monotonic() < ready_deadline:
        if len(list(run_dir.glob("ready-*.json"))) == args.workers:
            break
        if any(proc.poll() is not None for _, proc in children):
            break
        time.sleep(0.02)
    ready_files = sorted(run_dir.glob("ready-*.json"))
    atomic_json(
        run_dir / "top-level-stage.json",
        {
            "controller_pid": os.getpid(),
            "configured_workers": args.workers,
            "started_workers": len(children),
            "ready_workers": len(ready_files),
            "worker_pids": [proc.pid for _, proc in children],
        },
    )
    gate.touch()

    expected = args.workers * args.compilers_per_worker
    helper_deadline = time.monotonic() + 8
    while time.monotonic() < helper_deadline:
        if len(list(run_dir.glob("helper-ready-*"))) == expected:
            break
        time.sleep(0.01)
    helper_ready = len(list(run_dir.glob("helper-ready-*")))
    fanout_gate.touch()
    compile_deadline = time.monotonic() + 12
    while time.monotonic() < compile_deadline:
        if len(list(run_dir.glob("compiled-ready-*"))) == expected:
            break
        time.sleep(0.02)
    compiled_ready = len(list(run_dir.glob("compiled-ready-*")))
    release.touch()

    worker_status = []
    for package, proc in children:
        worker_status.append({"package": package, "returncode": proc.wait()})

    reports = []
    for path in sorted(run_dir.glob("worker-*.json")):
        reports.append(json.loads(path.read_text()))
    errors = controller_errors + [error for report in reports for error in report.get("errors", [])]
    records = [record for report in reports for record in report.get("records", [])]
    nested = sorted(run_dir.glob("nested-*.json"))
    if (
        errors
        or len(children) != args.workers
        or len(ready_files) != args.workers
        or len(nested) != args.workers
        or len(records) != expected
        or any(item["returncode"] != 0 for item in worker_status)
    ):
        atomic_json(
            run_dir / "failure.json",
            {
                "errno_eagain": any(item.get("errno") == errno.EAGAIN for item in errors),
                "errors": errors,
                "records": len(records),
                "expected": expected,
                "compiled_ready": compiled_ready,
                "helper_ready": helper_ready,
                "worker_status": worker_status,
            },
        )
        print(f"ABI_MATRIX_FAILED records={len(records)} expected={expected} errors={len(errors)}", file=sys.stderr)
        return 2

    records.sort(key=lambda item: (item["package"], item["unit"]))
    input_manifest = json.loads((input_root / "input-manifest.json").read_text())
    stage = {
        "workers": args.workers,
        "compilers_per_worker": args.compilers_per_worker,
        "packages_reaching_descendants": len(nested),
        "compiler_descendants": expected,
    }
    atomic_json(output_root / "descendant-stage.json", stage)
    manifest = {
        "schema": "abi-matrix-v1",
        "workers": args.workers,
        "compilers_per_worker": args.compilers_per_worker,
        "input_manifest_sha256": hashlib.sha256((input_root / "input-manifest.json").read_bytes()).hexdigest(),
        "source_count": len(input_manifest["sources"]),
        "object_count": len(records),
        "records": records,
    }
    atomic_json(output_root / "abi-manifest.json", manifest)
    print(f"ABI_MATRIX_OK=1 objects={len(records)} workers={args.workers} compilers_per_worker={args.compilers_per_worker}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
