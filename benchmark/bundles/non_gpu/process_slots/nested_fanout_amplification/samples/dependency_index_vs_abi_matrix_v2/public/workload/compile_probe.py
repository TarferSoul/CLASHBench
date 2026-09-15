#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def atomic_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--object", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--fanout-gate", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--package", type=int, required=True)
    parser.add_argument("--unit", type=int, required=True)
    args = parser.parse_args()
    source = Path(args.source)
    obj = Path(args.object)
    run_dir = Path(args.run_dir)
    record_path = run_dir / f"unit-{args.package:02d}-{args.unit:02d}.json"
    stderr_path = run_dir / f"compiler-{args.package:02d}-{args.unit:02d}.stderr"
    (run_dir / f"helper-ready-{args.package:02d}-{args.unit:02d}").touch()
    fanout_gate = Path(args.fanout_gate)
    gate_deadline = time.monotonic() + 8
    while not fanout_gate.exists():
        if time.monotonic() >= gate_deadline:
            return 3
        time.sleep(0.01)
    try:
        with stderr_path.open("w") as stderr:
            proc = subprocess.Popen(
                ["cc", "-std=c11", "-O0", "-g0", "-fno-ident", "-c", str(source), "-o", str(obj)],
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                close_fds=True,
            )
            rc = proc.wait()
    except OSError as exc:
        item = {
            "package": args.package,
            "unit": args.unit,
            "errno": exc.errno,
            "error": str(exc),
            "operation": "spawn_compiler",
        }
        atomic_json(run_dir / f"spawn-error-{args.package:02d}-{args.unit:02d}.json", item)
        return 2
    if rc != 0:
        stderr = stderr_path.read_text(errors="replace")
        item = {
            "package": args.package,
            "unit": args.unit,
            "errno": errno.EAGAIN if "Resource temporarily unavailable" in stderr else None,
            "error": stderr[-1000:],
            "operation": "compiler_child",
            "returncode": rc,
        }
        atomic_json(record_path, {"ok": False, "errors": [item]})
        return 2
    try:
        symbols = subprocess.run(
            ["nm", "-g", "--defined-only", str(obj)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.splitlines()
    except OSError as exc:
        item = {"package": args.package, "unit": args.unit, "errno": exc.errno, "error": str(exc), "operation": "spawn_nm"}
        atomic_json(record_path, {"ok": False, "errors": [item]})
        return 2
    atomic_json(
        record_path,
        {
            "ok": True,
            "package": args.package,
            "unit": args.unit,
            "source": str(source),
            "object": str(obj),
            "object_sha256": hashlib.sha256(obj.read_bytes()).hexdigest(),
            "defined_symbols": len(symbols),
            "compiler_pid": os.getpid(),
        },
    )
    (run_dir / f"compiled-ready-{args.package:02d}-{args.unit:02d}").touch()
    release = Path(args.release)
    deadline = time.monotonic() + 30
    while not release.exists():
        if time.monotonic() >= deadline:
            return 3
        time.sleep(0.02)
    return 0


if __name__ == "__main__":
    sys.exit(main())
