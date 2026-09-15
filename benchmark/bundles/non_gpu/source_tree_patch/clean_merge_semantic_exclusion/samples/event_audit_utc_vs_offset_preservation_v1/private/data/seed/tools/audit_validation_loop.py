#!/usr/bin/env python3
"""Run the focused UTC audit serialization suite as a development worker."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def write_state(path: Path, state: dict[str, object]) -> None:
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--interval", type=float, default=0.25)
    args = parser.parse_args()
    args.state.parent.mkdir(parents=True, exist_ok=True)
    stop = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    cycles = passing = failing = 0
    started = time.time()
    write_state(
        args.state,
        {
            "pid": os.getpid(),
            "started_at": started,
            "cycles": 0,
            "passing_cycles": 0,
            "failing_cycles": 0,
            "last_rc": None,
            "last_passed": False,
        },
    )
    while not stop:
        proc = subprocess.run(
            [sys.executable, "-m", "unittest", "-q", "tests.test_utc_audit_contract"],
            cwd=args.checkout,
            env={**os.environ, "PYTHONPATH": str(args.checkout / "src")},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        cycles += 1
        passing += int(proc.returncode == 0)
        failing += int(proc.returncode != 0)
        write_state(
            args.state,
            {
                "pid": os.getpid(),
                "started_at": started,
                "cycles": cycles,
                "passing_cycles": passing,
                "failing_cycles": failing,
                "last_rc": proc.returncode,
                "last_passed": proc.returncode == 0,
                "last_output": proc.stdout[-1200:],
                "updated_at": time.time(),
            },
        )
        if not stop:
            time.sleep(max(0.05, args.interval))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
