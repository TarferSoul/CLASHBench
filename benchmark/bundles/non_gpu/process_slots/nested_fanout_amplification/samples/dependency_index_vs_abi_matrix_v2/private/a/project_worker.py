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
children = []


def request_stop(_signum, _frame) -> None:
    global stopping
    stopping = True
    for proc in children:
        if proc.poll() is None:
            proc.terminate()


def atomic_json(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=int, required=True)
    parser.add_argument("--analyzers", type=int, required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--input-root", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--analyzer-program", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    state_root = Path(args.state_root)
    input_root = Path(args.input_root)
    sources = sorted(input_root.glob("*.py"))
    if not sources:
        raise SystemExit("no source fixtures")
    (state_root / f"worker-{args.project:02d}.pid").write_text(f"{os.getpid()}\n")
    generation = 0
    while not stopping:
        generation += 1
        generation_root = state_root / "indexes" / f"project-{args.project:02d}" / f"generation-{generation:06d}"
        generation_root.mkdir(parents=True, exist_ok=True)
        children.clear()
        launch_errors = []
        for slot in range(args.analyzers):
            source = sources[(args.project * args.analyzers + slot + generation) % len(sources)]
            output = generation_root / f"analysis-{slot:02d}.json"
            while not stopping:
                try:
                    proc = subprocess.Popen(
                        [
                            sys.executable,
                            args.analyzer_program,
                            "--source",
                            str(source),
                            "--output",
                            str(output),
                            "--seconds",
                            str(args.seconds),
                            "--project",
                            str(args.project),
                            "--slot",
                            str(slot),
                            "--generation",
                            str(generation),
                        ],
                        close_fds=True,
                    )
                    children.append(proc)
                    break
                except BlockingIOError as exc:
                    launch_errors.append({"slot": slot, "errno": exc.errno, "error": str(exc)})
                    time.sleep(0.05)
            if stopping:
                break
        atomic_json(
            state_root / f"phase-{args.project:02d}.json",
            {
                "project": args.project,
                "worker_pid": os.getpid(),
                "generation": generation,
                "configured_analyzers": args.analyzers,
                "analyzer_pids": [proc.pid for proc in children],
                "launch_errors": launch_errors,
            },
        )
        if stopping:
            break
        statuses = [proc.wait() for proc in children]
        if stopping:
            break
        records = sorted(generation_root.glob("analysis-*.json"))
        if statuses != [0] * args.analyzers or len(records) != args.analyzers:
            atomic_json(
                state_root / f"failure-{args.project:02d}.json",
                {"generation": generation, "statuses": statuses, "record_count": len(records)},
            )
            return 2
        atomic_json(
            state_root / f"project-{args.project:02d}.json",
            {
                "project": args.project,
                "worker_pid": os.getpid(),
                "completed_generation": generation,
                "analysis_records": len(records),
            },
        )
    for proc in children:
        if proc.poll() is None:
            proc.terminate()
    for proc in children:
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
