#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import os
import signal
import sys
import time


STOP = False


def proc_start_time(pid):
    try:
        text = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        rest = text[text.rfind(") ") + 2 :].split()
        return int(rest[19])
    except Exception:
        return None


def atomic_json(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def update_manifest(path, job_id, state):
    data = {}
    if os.path.exists(path):
        try:
            data = json.load(open(path, "r", encoding="utf-8"))
        except Exception:
            data = {}
    data[job_id] = {
        "current_byte_offset": state["current_byte_offset"],
        "chunk_count": state["chunk_count"],
        "heartbeat_count": state["heartbeat_count"],
        "last_seen_step": state["last_seen_step"],
        "rolling_sha256": state["rolling_sha256"],
        "updated_at": state["updated_at"],
    }
    atomic_json(path, data)


def handle_stop(_signum, _frame):
    global STOP
    STOP = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--cursor", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    pid_path = os.path.join(args.state_dir, f"{args.job_id}.pid")
    state_path = os.path.join(args.state_dir, f"{args.job_id}.json")
    manifest_path = os.path.join(args.state_dir, "cache_manifest.json")
    with open(pid_path, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")

    conn = http.client.HTTPConnection(args.host, args.port, timeout=5)
    path = f"/api/ci/jobs/{args.job_id}/logs?follow=1&cursor={args.cursor}"
    conn.request("GET", path, headers={"Accept": "text/plain"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise SystemExit(f"log stream returned {resp.status}")

    digest = hashlib.sha256()
    offset = args.cursor
    chunk_count = 0
    heartbeat_count = 0
    warning_count = 0
    last_seen_step = ""
    state = {
        "job_id": args.job_id,
        "pid": os.getpid(),
        "start_time": proc_start_time(os.getpid()),
        "starting_cursor": args.cursor,
        "current_byte_offset": offset,
        "chunk_count": 0,
        "heartbeat_count": 0,
        "warning_count": 0,
        "last_seen_step": "",
        "rolling_sha256": hashlib.sha256(b"").hexdigest(),
        "updated_at": time.time(),
    }
    atomic_json(state_path, state)
    update_manifest(manifest_path, args.job_id, state)

    while not STOP:
        payload = resp.read(128)
        if not payload:
            time.sleep(0.05)
            continue
        digest.update(payload)
        text = payload.decode("utf-8", errors="replace")
        offset += len(payload)
        chunk_count += 1
        if "heartbeat" in text:
            heartbeat_count += 1
        if "WARNING" in text:
            warning_count += 1
        marker = " step="
        if marker in text:
            tail = text.split(marker, 1)[1]
            last_seen_step = tail.split(" first_failed_test=", 1)[0].strip()
        state = {
            "job_id": args.job_id,
            "pid": os.getpid(),
            "start_time": proc_start_time(os.getpid()),
            "starting_cursor": args.cursor,
            "current_byte_offset": offset,
            "chunk_count": chunk_count,
            "heartbeat_count": heartbeat_count,
            "warning_count": warning_count,
            "last_seen_step": last_seen_step,
            "rolling_sha256": digest.hexdigest(),
            "updated_at": time.time(),
        }
        atomic_json(state_path, state)
        update_manifest(manifest_path, args.job_id, state)
    try:
        conn.close()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

