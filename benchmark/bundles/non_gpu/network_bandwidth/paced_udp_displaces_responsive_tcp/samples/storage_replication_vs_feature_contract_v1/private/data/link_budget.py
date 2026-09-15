#!/usr/bin/env python3
"""Shared socket-level link budget used when the sandbox cannot change tc state."""
import argparse
import fcntl
import json
import os
import pathlib
import tempfile
import time


def _write(path, value):
    path = pathlib.Path(path)
    owner = path.stat() if path.exists() else None
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        if owner is not None and os.geteuid() == 0:
            os.fchown(fd, owner.st_uid, owner.st_gid)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
        os.chmod(name, 0o660)
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


class SharedTokenBucket:
    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.lock_path = pathlib.Path(str(self.path) + ".lock")

    def consume(self, amount):
        amount = int(amount)
        if amount <= 0:
            return
        while True:
            with self.lock_path.open("a+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                state = json.loads(self.path.read_text())
                now = time.monotonic()
                elapsed = max(0.0, now - float(state.get("updated_monotonic", now)))
                rate = float(state["rate_bps"])
                capacity = float(state["capacity_bytes"])
                tokens = min(capacity, float(state.get("tokens", capacity)) + elapsed * rate / 8.0)
                if tokens >= amount:
                    state["tokens"] = tokens - amount
                    state["updated_monotonic"] = now
                    state["bytes"] = int(state.get("bytes", 0)) + amount
                    state["packets"] = int(state.get("packets", 0)) + 1
                    _write(self.path, state)
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    return
                state["tokens"] = tokens
                state["updated_monotonic"] = now
                state["contention_events"] = int(state.get("contention_events", 0)) + 1
                _write(self.path, state)
                wait = max(0.001, (amount - tokens) * 8.0 / rate)
                fcntl.flock(lock, fcntl.LOCK_UN)
            time.sleep(min(wait, 0.1))


def init(path, rate_bps, capacity_bytes):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.touch(mode=0o660, exist_ok=True)
    pathlib.Path(str(target) + ".lock").touch(mode=0o660, exist_ok=True)
    now = time.monotonic()
    _write(target, {
        "mode": "userspace_token_bucket",
        "rate_bps": int(rate_bps),
        "capacity_bytes": int(capacity_bytes),
        "tokens": int(capacity_bytes),
        "updated_monotonic": now,
        "bytes": 0,
        "packets": 0,
        "contention_events": 0,
    })


def snapshot(path):
    bucket = SharedTokenBucket(path)
    with bucket.lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(bucket.path.read_text())
        now = time.monotonic()
        elapsed = max(0.0, now - float(state.get("updated_monotonic", now)))
        tokens = min(float(state["capacity_bytes"]), float(state.get("tokens", 0)) + elapsed * float(state["rate_bps"]) / 8.0)
        state["tokens"] = tokens
        state["updated_monotonic"] = now
        _write(bucket.path, state)
        fcntl.flock(lock, fcntl.LOCK_UN)
    state["backlog_bytes"] = max(0, int(float(state["capacity_bytes"]) - float(state.get("tokens", 0))))
    print(json.dumps(state, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    init_parser = sub.add_parser("init")
    init_parser.add_argument("--path", required=True)
    init_parser.add_argument("--rate-bps", type=int, required=True)
    init_parser.add_argument("--capacity-bytes", type=int, required=True)
    consume_parser = sub.add_parser("consume")
    consume_parser.add_argument("--path", required=True)
    consume_parser.add_argument("--bytes", type=int, required=True)
    snapshot_parser = sub.add_parser("snapshot")
    snapshot_parser.add_argument("--path", required=True)
    args = parser.parse_args()
    if args.command == "init":
        init(args.path, args.rate_bps, args.capacity_bytes)
    elif args.command == "consume":
        SharedTokenBucket(args.path).consume(args.bytes)
    else:
        snapshot(args.path)


if __name__ == "__main__":
    main()
