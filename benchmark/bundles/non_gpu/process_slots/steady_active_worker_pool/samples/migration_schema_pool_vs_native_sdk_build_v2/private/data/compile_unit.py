#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pathlib
import subprocess
import time


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(temporary, path)


def read_int(path):
    return int(path.read_text().strip())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--unit", type=int, required=True)
    parser.add_argument("--expected", type=int, required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--include", required=True)
    parser.add_argument("--object", required=True)
    parser.add_argument("--ready-root", required=True)
    parser.add_argument("--error-root", required=True)
    parser.add_argument("--cgroup", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    args = parser.parse_args()
    ready_root = pathlib.Path(args.ready_root)
    error_root = pathlib.Path(args.error_root)
    cgroup = pathlib.Path(args.cgroup)
    ready_root.mkdir(parents=True, exist_ok=True)
    error_root.mkdir(parents=True, exist_ok=True)
    atomic_json(ready_root / f"unit_{args.unit:02d}.json", {
        "unit": args.unit, "pid": os.getpid(), "started_at": time.time(),
    })
    deadline = time.monotonic() + args.deadline
    cohort = 0
    saturated = False
    while time.monotonic() < deadline:
        cohort = len(list(ready_root.glob("unit_*.json")))
        current = read_int(cgroup / "pids.current")
        maximum = read_int(cgroup / "pids.max")
        if cohort >= args.expected:
            break
        if current >= maximum:
            saturated = True
            break
        time.sleep(0.01)
    command = [
        "cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-I", args.include,
        "-c", args.source, "-o", args.object,
    ]
    try:
        compiler = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as error:
        atomic_json(error_root / f"unit_{args.unit:02d}.json", {
            "unit": args.unit,
            "errno": error.errno,
            "error": str(error),
            "cohort_size": cohort,
            "pids_current": read_int(cgroup / "pids.current"),
            "pids_max": read_int(cgroup / "pids.max"),
        })
        return 75 if error.errno == errno.EAGAIN else 76
    stdout, stderr = compiler.communicate()
    if cohort < args.expected:
        pathlib.Path(args.object).unlink(missing_ok=True)
        atomic_json(error_root / f"unit_{args.unit:02d}.json", {
            "unit": args.unit,
            "errno": errno.EAGAIN if saturated else 0,
            "error": "required worker cohort was not reached",
            "cohort_size": cohort,
            "compiler_rc": compiler.returncode,
            "compiler_stderr": stderr[-1000:],
            "pids_current": read_int(cgroup / "pids.current"),
            "pids_max": read_int(cgroup / "pids.max"),
        })
        return 75 if saturated else 74
    if compiler.returncode != 0:
        atomic_json(error_root / f"unit_{args.unit:02d}.json", {
            "unit": args.unit, "errno": 0, "error": "compiler failed",
            "compiler_rc": compiler.returncode, "stdout": stdout[-1000:], "stderr": stderr[-1000:],
        })
        return 76
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
