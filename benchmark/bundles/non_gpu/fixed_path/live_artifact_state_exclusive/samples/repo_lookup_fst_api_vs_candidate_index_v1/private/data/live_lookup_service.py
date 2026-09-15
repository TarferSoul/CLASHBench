#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time


running = True


def handle_signal(signum, frame):
    global running
    running = False


def atomic_write_json(path, payload):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def run_tool(args):
    proc = subprocess.run(
        ["/usr/local/bin/repo-index-tool", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
    )
    return proc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--interval", type=float, default=0.25)
    args = parser.parse_args()

    pathlib.Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.state).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n", encoding="utf-8")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    count = 0
    last_ok = False
    last_error = ""
    last_digest = ""
    while running:
        validate = run_tool(["validate", "--path", args.index, "--manifest", args.manifest])
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if validate.returncode == 0:
            count += 1
            last_ok = True
            last_error = ""
            try:
                last_digest = json.loads(validate.stdout).get("dataset_digest", "")
            except json.JSONDecodeError:
                last_digest = ""
        else:
            last_ok = False
            last_error = (validate.stderr + validate.stdout)[-800:]
        state = {
            "pid": os.getpid(),
            "status": "healthy" if last_ok else "unhealthy",
            "served_query_count": count,
            "last_ok": last_ok,
            "last_error": last_error,
            "last_dataset_digest": last_digest,
            "index_path": args.index,
            "updated_at": now,
        }
        atomic_write_json(args.state, state)
        time.sleep(args.interval)
    atomic_write_json(
        args.state,
        {
            "pid": os.getpid(),
            "status": "stopped",
            "served_query_count": count,
            "last_ok": last_ok,
            "last_error": last_error,
            "last_dataset_digest": last_digest,
            "index_path": args.index,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
