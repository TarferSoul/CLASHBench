#!/usr/bin/env python3
import argparse
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
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--fanout-gate", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--package", type=int, required=True)
    parser.add_argument("--compilers", type=int, required=True)
    args = parser.parse_args()

    input_root = Path(args.input)
    output_root = Path(args.output)
    run_dir = Path(args.run_dir)
    package_name = f"package_{args.package:02d}"
    package_input = input_root / package_name
    package_output = output_root / "objects" / package_name
    package_output.mkdir(parents=True, exist_ok=True)
    ready = run_dir / f"ready-{args.package:02d}.json"
    atomic_json(ready, {"package": args.package, "worker_pid": os.getpid(), "state": "ready"})

    gate = Path(args.gate)
    deadline = time.monotonic() + 8
    while not gate.exists():
        if time.monotonic() >= deadline:
            atomic_json(run_dir / f"worker-{args.package:02d}.json", {"ok": False, "reason": "gate_timeout"})
            return 3
        time.sleep(0.02)

    children = []
    errors = []
    helper_program = Path(__file__).with_name("compile_probe.py")
    for unit in range(args.compilers):
        source = package_input / f"unit_{unit:02d}.c"
        obj = package_output / f"unit_{unit:02d}.o"
        try:
            proc = subprocess.Popen(
                [
                    sys.executable,
                    str(helper_program),
                    "--source",
                    str(source),
                    "--object",
                    str(obj),
                    "--run-dir",
                    str(run_dir),
                    "--fanout-gate",
                    args.fanout_gate,
                    "--release",
                    args.release,
                    "--package",
                    str(args.package),
                    "--unit",
                    str(unit),
                ],
                close_fds=True,
            )
            children.append((unit, proc, source, obj))
        except OSError as exc:
            item = {
                "package": args.package,
                "unit": unit,
                "errno": exc.errno,
                "error": str(exc),
                "operation": "spawn_compile_helper",
            }
            errors.append(item)
            atomic_json(run_dir / f"spawn-error-{args.package:02d}-{unit:02d}.json", item)

    if len(children) == args.compilers:
        atomic_json(
            run_dir / f"nested-{args.package:02d}.json",
            {
                "package": args.package,
                "worker_pid": os.getpid(),
                "compile_helper_pids": [proc.pid for _, proc, _, _ in children],
            },
        )

    records = []
    for unit, proc, source, obj in children:
        rc = proc.wait()
        record_path = run_dir / f"unit-{args.package:02d}-{unit:02d}.json"
        if rc != 0 or not record_path.is_file():
            spawn_error = run_dir / f"spawn-error-{args.package:02d}-{unit:02d}.json"
            if spawn_error.is_file():
                errors.append(json.loads(spawn_error.read_text()))
            elif record_path.is_file():
                errors.extend(json.loads(record_path.read_text()).get("errors", []))
            else:
                errors.append(
                    {
                        "package": args.package,
                        "unit": unit,
                        "errno": None,
                        "error": "compile helper exited without a record",
                        "operation": "compile_helper",
                        "returncode": rc,
                    }
                )
            continue
        raw = json.loads(record_path.read_text())
        if not raw.get("ok"):
            errors.extend(raw.get("errors", []))
            continue
        records.append(
            {
                "package": args.package,
                "unit": unit,
                "source": str(source.relative_to(input_root)),
                "object": str(obj.relative_to(output_root)),
                "object_sha256": raw["object_sha256"],
                "defined_symbols": raw["defined_symbols"],
            }
        )
    result = {
        "ok": not errors and len(records) == args.compilers,
        "package": args.package,
        "worker_pid": os.getpid(),
        "compiler_count": args.compilers,
        "records": records,
        "errors": errors,
    }
    atomic_json(run_dir / f"worker-{args.package:02d}.json", result)
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    sys.exit(main())
