#!/usr/bin/env python3
"""Feature scoring worker that pins one schema generation with a read lease."""

import argparse
import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import redis_rwlock  # noqa: E402

stopping = False


def stop(_signum, _frame):
    global stopping
    stopping = True


def proc_start(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().split()
        return fields[21]
    except (OSError, IndexError):
        return ""


def write_json(path, value):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--max-seconds", type=float, default=0)
    args = ap.parse_args()
    state = Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    metadata = state / "metadata.json"
    progress_log = state / "scoring_progress.jsonl"
    token = redis_rwlock.token("reader")
    owner = os.environ["READER_OWNER_PREFIX"] + token
    pid = os.getpid()
    started = time.time()
    base = {
        "pid": pid,
        "start_time": proc_start(pid),
        "token": token,
        "owner_key": owner,
        "index": args.index,
        "generation": "",
        "progress": 0,
        "ready": False,
        "started_at": started,
        "last_renewal": None,
    }
    write_json(metadata, base)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    r = redis_rwlock.conn()
    acquired = False
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not stopping:
            if redis_rwlock.acquire_read(r, owner, token, int(os.environ["READER_TTL_SECONDS"]), token):
                acquired = True
                break
            time.sleep(0.1)
        if not acquired:
            base["error"] = "read lease unavailable"
            write_json(metadata, base)
            return 2
        generation = r.command("GET", os.environ["ACTIVE_KEY"])
        schema = r.command("GET", os.environ["GENERATION_PREFIX"] + generation)
        if not generation or not schema:
            base["error"] = "active generation missing"
            write_json(metadata, base)
            return 3
        records = [line for line in Path(os.environ["DATA_ROOT"], "partitions.jsonl").read_text().splitlines() if line]
        base["generation"] = generation
        base["ready"] = True
        base["ready_at"] = time.time()
        write_json(metadata, base)
        last_renew = time.monotonic()
        started_mono = time.monotonic()
        with progress_log.open("a") as stream:
            while not stopping:
                if args.max_seconds and time.monotonic() - started_mono >= args.max_seconds:
                    break
                if time.monotonic() - last_renew >= float(os.environ["RENEW_INTERVAL_SECONDS"]):
                    if not redis_rwlock.renew_read(r, owner, token, int(os.environ["READER_TTL_SECONDS"])):
                        base["error"] = "read lease renewal failed"
                        write_json(metadata, base)
                        return 4
                    last_renew = time.monotonic()
                    base["last_renewal"] = time.time()
                record = records[base["progress"] % len(records)]
                digest = hashlib.sha256((schema + "\n" + record).encode()).hexdigest()
                base["progress"] += 1
                base["last_digest"] = digest
                base["last_record"] = record.split(",", 1)[0]
                stream.write(json.dumps({"at": time.time(), "unit": base["progress"], "digest": digest}) + "\n")
                stream.flush()
                write_json(metadata, base)
                time.sleep(0.25)
        return 0
    finally:
        if acquired and not os.environ.get("PRESERVE_LEASE_ON_EXIT"):
            redis_rwlock.release_read(r, owner, token, token)
        r.close()
        base["ready"] = False
        base["stopped_at"] = time.time()
        write_json(metadata, base)


if __name__ == "__main__":
    raise SystemExit(main())
