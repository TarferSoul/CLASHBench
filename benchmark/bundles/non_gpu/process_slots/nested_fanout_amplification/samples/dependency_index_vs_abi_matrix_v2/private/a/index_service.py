#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


stopping = False
workers = []


def request_stop(_signum, _frame) -> None:
    global stopping
    stopping = True
    for proc in workers:
        if proc.poll() is None:
            proc.terminate()


def atomic_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def pid_alive(pid: int) -> bool:
    try:
        state = Path(f"/proc/{pid}/stat").read_text().split()[2]
        return state != "Z"
    except (OSError, IndexError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--projects", type=int, required=True)
    parser.add_argument("--analyzers", type=int, required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--input-root", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--worker-program", required=True)
    parser.add_argument("--analyzer-program", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    state_root = Path(args.state_root)
    state_root.mkdir(parents=True, exist_ok=True)
    (state_root / "service.pid").write_text(f"{os.getpid()}\n")
    for project in range(args.projects):
        proc = subprocess.Popen(
            [
                sys.executable,
                args.worker_program,
                "--project",
                str(project),
                "--analyzers",
                str(args.analyzers),
                "--seconds",
                str(args.seconds),
                "--input-root",
                args.input_root,
                "--state-root",
                args.state_root,
                "--analyzer-program",
                args.analyzer_program,
            ],
            close_fds=True,
        )
        workers.append(proc)

    while not stopping:
        phases = []
        progress = []
        for path in sorted(state_root.glob("phase-*.json")):
            try:
                phases.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        for path in sorted(state_root.glob("project-*.json")):
            try:
                progress.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        active_analyzers = sum(
            1 for phase in phases for pid in phase.get("analyzer_pids", []) if pid_alive(int(pid))
        )
        worker_states = [proc.poll() for proc in workers]
        atomic_json(
            state_root / "health.json",
            {
                "healthy": len(workers) == args.projects and all(state is None for state in worker_states),
                "service_pid": os.getpid(),
                "project_workers": [proc.pid for proc in workers],
                "configured_projects": args.projects,
                "configured_analyzers_per_project": args.analyzers,
                "active_analyzers": active_analyzers,
                "phase_projects": len(phases),
                "completed_generations": sum(int(item.get("completed_generation", 0)) for item in progress),
            },
        )
        if any(state is not None for state in worker_states):
            return 2
        time.sleep(0.1)

    for proc in workers:
        if proc.poll() is None:
            proc.terminate()
    for proc in workers:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    atomic_json(
        state_root / "health.json",
        {
            "healthy": False,
            "service_pid": os.getpid(),
            "project_workers": [proc.pid for proc in workers],
            "stopped_normally": True,
        },
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
