#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import subprocess
import sys
import time


running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_write(path: pathlib.Path, payload: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def main() -> int:
    checkout = pathlib.Path(sys.argv[1]).resolve()
    health_path = pathlib.Path(sys.argv[2]).resolve()
    ready_path = pathlib.Path(sys.argv[3]).resolve()
    test_module = sys.argv[4]
    interval = float(sys.argv[5])
    pid_path = pathlib.Path(sys.argv[6]).resolve()
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(f"{os.getpid()}\n")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    env = os.environ.copy()
    env["PYTHONPATH"] = str(checkout / "src")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    completed = 0
    while running:
        proc = subprocess.run(
            [sys.executable, "-m", "unittest", "-q", test_module],
            cwd=checkout,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=20,
        )
        completed += 1
        payload = {
            "pid": os.getpid(),
            "completed_runs": completed,
            "last_rc": proc.returncode,
            "last_output_tail": proc.stdout[-1200:],
            "updated_at": time.time(),
        }
        atomic_write(health_path, payload)
        if proc.returncode == 0 and not ready_path.exists():
            ready_path.write_text("ready\n")
        time.sleep(interval)
    try:
        pid_path.unlink()
    except FileNotFoundError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
