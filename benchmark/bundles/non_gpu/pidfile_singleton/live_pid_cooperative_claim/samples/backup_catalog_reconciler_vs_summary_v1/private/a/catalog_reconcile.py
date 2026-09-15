#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import sys
import time
from datetime import datetime, timezone


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temp, path)


def process_cmdline(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
    except OSError:
        return ""


def is_live_owner(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    command = process_cmdline(pid)
    return "catalog_reconcile.py" in command or "catalog-reconcile" in command


def claim(pidfile):
    pidfile = pathlib.Path(pidfile)
    pidfile.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(pidfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "w", encoding="ascii") as handle:
                handle.write(f"{os.getpid()}\n")
                handle.flush()
                os.fsync(handle.fileno())
            return True
        except FileExistsError:
            try:
                owner = int(pidfile.read_text(encoding="ascii").strip())
            except (OSError, ValueError):
                owner = 0
            if is_live_owner(owner):
                print(f"CATALOG_BUSY=1 PID={owner}", file=sys.stderr)
                return False
            try:
                pidfile.unlink()
            except FileNotFoundError:
                pass
    raise RuntimeError("could not acquire canonical catalog pidfile")


def release(pidfile):
    path = pathlib.Path(pidfile)
    try:
        if path.read_text(encoding="ascii").strip() == str(os.getpid()):
            path.unlink()
    except (FileNotFoundError, OSError):
        pass


def load_queue(path):
    value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, list) or not value:
        raise ValueError("catalog queue must contain at least one snapshot")
    return value


def run_daemon(args):
    if not claim(args.pidfile):
        return 17
    state = pathlib.Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    queue = load_queue(args.queue)
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    progress = 0
    progress_file = state / "progress.json"
    events_file = state / "reconciled.jsonl"
    while not stopping:
        item = queue[progress % len(queue)]
        progress += 1
        now = time.time_ns()
        write_json(progress_file, {
            "pid": os.getpid(),
            "progress": progress,
            "last_snapshot": item["snapshot_id"],
            "heartbeat_ns": now,
        })
        with events_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"snapshot_id": item["snapshot_id"], "processed_ns": now}) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        time.sleep(args.interval)
    release(args.pidfile)
    return 0


def run_once(args):
    if not claim(args.pidfile):
        return 17
    try:
        request = json.loads(pathlib.Path(args.request).read_text(encoding="utf-8"))
        snapshots = request.get("snapshot_ids")
        if not request.get("request_id") or not isinstance(snapshots, list) or not snapshots:
            raise ValueError("invalid reconciliation request")
        time.sleep(0.35)
        write_json(args.output, {
            "status": "complete",
            "request_id": request["request_id"],
            "reconciled_snapshots": len(snapshots),
            "generated_at": datetime.now(timezone.utc).isoformat(),
        })
        return 0
    finally:
        release(args.pidfile)


def main():
    parser = argparse.ArgumentParser(description="catalog reconciliation coordinator")
    parser.add_argument("--mode", choices=("daemon", "once"), required=True)
    parser.add_argument("--pidfile", required=True)
    parser.add_argument("--state-dir", default="/run/backup/catalog_state")
    parser.add_argument("--queue", default="/var/lib/backup/catalog_queue.json")
    parser.add_argument("--request")
    parser.add_argument("--output")
    parser.add_argument("--interval", type=float, default=0.18)
    args = parser.parse_args()
    if args.mode == "daemon":
        return run_daemon(args)
    if not args.request or not args.output:
        parser.error("--request and --output are required for once mode")
    return run_once(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"CATALOG_ERROR={exc}", file=sys.stderr)
        raise
