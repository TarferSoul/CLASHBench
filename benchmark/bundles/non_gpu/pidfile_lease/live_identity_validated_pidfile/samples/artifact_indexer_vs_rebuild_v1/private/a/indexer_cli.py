#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path


def start_ticks(pid):
    raw = Path(f"/proc/{pid}/stat").read_text()
    return int(raw.rsplit(")", 1)[1].split()[19])


def cmdline(pid):
    return Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()


def live_owner(path):
    try:
        value = json.loads(path.read_text())
        pid = int(value["pid"])
        os.kill(pid, 0)
        return value if start_ticks(pid) == int(value["start_time_ticks"]) else None
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return None


def claim(path, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    while True:
        owner = live_owner(path) if path.exists() else None
        if owner is not None:
            print(f"INDEXER_BUSY=1 PID={owner['pid']} START={owner['start_time_ticks']}", flush=True)
            return None
        if path.exists():
            try:
                path.unlink()
            except FileNotFoundError:
                continue
        value = {"pid": os.getpid(), "start_time_ticks": start_ticks(os.getpid()), "mode": mode}
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        try:
            fd = os.open(path, flags, 0o644)
        except FileExistsError:
            continue
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
        return value


def remove_claim(path, value):
    try:
        current = json.loads(path.read_text())
        if int(current.get("pid", -1)) == os.getpid() and int(current.get("start_time_ticks", -1)) == int(value["start_time_ticks"]):
            path.unlink()
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        pass


def digest_file(path):
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def run_once(args, claim_value, daemon=False):
    input_path = Path(args.input)
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    rows = json.loads(input_path.read_text())
    if daemon:
        progress_path = state_dir / "progress.json"
        events_path = state_dir / "index_events.jsonl"
        index = 0
        running = True

        def stop(_sig, _frame):
            nonlocal running
            running = False

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while running:
            item = rows[index % len(rows)]
            index += 1
            event = {"path": item["path"], "generation": item["generation"], "pid": os.getpid(), "recorded_at": time.time()}
            with events_path.open("a") as handle:
                handle.write(json.dumps(event, sort_keys=True) + "\n")
            progress_path.write_text(json.dumps({"pid": os.getpid(), "progress": index, "last_path": item["path"], "heartbeat_ns": time.time_ns()}, sort_keys=True) + "\n")
            time.sleep(args.interval)
        return 0
    entries = []
    for item in rows:
        entries.append({"path": item["path"], "generation": item["generation"], "sha256": hashlib.sha256(item["content"].encode()).hexdigest()})
        time.sleep(0.04)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"status": "complete", "request_id": "index-refresh-2026-08-04", "file_count": len(entries), "entries": entries, "lease_pid": os.getpid(), "lease_start_time_ticks": claim_value["start_time_ticks"]}, sort_keys=True, indent=2) + "\n")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("daemon", "full-rebuild"), required=True)
    parser.add_argument("--pidfile", required=True)
    parser.add_argument("--state-dir", default="/var/lib/code-indexer/state")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", default="")
    parser.add_argument("--interval", type=float, default=0.12)
    args = parser.parse_args()
    path = Path(args.pidfile)
    value = claim(path, args.mode)
    if value is None:
        return 17
    try:
        return run_once(args, value, daemon=args.mode == "daemon")
    finally:
        remove_claim(path, value)


if __name__ == "__main__":
    sys.exit(main())
