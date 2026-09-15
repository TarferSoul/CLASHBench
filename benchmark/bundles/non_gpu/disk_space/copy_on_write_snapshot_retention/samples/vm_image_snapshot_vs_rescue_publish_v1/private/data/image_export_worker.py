#!/usr/bin/env python3
"""Continuously verify and export a consistent virtual-machine image snapshot."""

import argparse
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


def write_json(path, payload):
    path = pathlib.Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def invoke(cowfs, *arguments):
    return subprocess.run(
        [sys.executable, cowfs, *arguments],
        check=True,
        text=True,
        capture_output=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cowfs", required=True)
    parser.add_argument("--volume", required=True)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--snapshot-spec", required=True)
    parser.add_argument("--current-spec", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--complete-request", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    cycle = 0
    bytes_streamed = 0
    while running:
        try:
            invoke(
                args.cowfs,
                "verify-spec",
                "--volume",
                args.volume,
                "--spec",
                args.snapshot_spec,
                "--snapshot",
                args.snapshot,
            )
            invoke(
                args.cowfs,
                "verify-spec",
                "--volume",
                args.volume,
                "--spec",
                args.current_spec,
            )
        except subprocess.CalledProcessError as exc:
            write_json(
                args.progress,
                {
                    "healthy": False,
                    "cycle": cycle,
                    "snapshot_uuid": args.snapshot,
                    "error_rc": exc.returncode,
                    "pid": os.getpid(),
                },
            )
            return 2
        cycle += 1
        bytes_streamed += 4 * 1024 * 1024
        write_json(
            args.progress,
            {
                "healthy": True,
                "cycle": cycle,
                "bytes_streamed": bytes_streamed,
                "snapshot_uuid": args.snapshot,
                "pid": os.getpid(),
                "phase": "verify_and_stream",
                "updated_unix": time.time(),
            },
        )
        if pathlib.Path(args.complete_request).exists():
            invoke(
                args.cowfs,
                "snapshot-delete",
                "--volume",
                args.volume,
                "--uuid",
                args.snapshot,
            )
            write_json(
                args.receipt,
                {
                    "completed": True,
                    "released_snapshot_uuid": args.snapshot,
                    "final_cycle": cycle,
                    "bytes_streamed": bytes_streamed,
                    "pid": os.getpid(),
                },
            )
            return 0
        time.sleep(0.15)
    return 143


if __name__ == "__main__":
    raise SystemExit(main())
