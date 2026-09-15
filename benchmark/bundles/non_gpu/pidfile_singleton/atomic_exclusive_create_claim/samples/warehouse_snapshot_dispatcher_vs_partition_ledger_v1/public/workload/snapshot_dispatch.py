#!/usr/bin/env python3
"""Bounded feature-store snapshot dispatcher and replay materializer."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import sys
import time


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def file_sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def proc_start_ticks():
    return int(pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21])


class ExclusivePidfile:
    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.fd = None
        self.inode = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            print(f"DISPATCHER_BUSY=1 PIDFILE={self.path} REASON=EEXIST", file=sys.stderr, flush=True)
            raise SystemExit(17)
        os.write(self.fd, f"{os.getpid()}\n".encode("ascii"))
        os.fsync(self.fd)
        stat = os.fstat(self.fd)
        self.inode = (stat.st_dev, stat.st_ino)
        print(f"SNAPSHOT_CLAIM_ACQUIRED=1 PID={os.getpid()} DEV={stat.st_dev} INODE={stat.st_ino}", flush=True)
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        try:
            current = self.path.stat()
            if (current.st_dev, current.st_ino) == self.inode:
                self.path.unlink()
        except FileNotFoundError:
            pass
        finally:
            if self.fd is not None:
                os.close(self.fd)


def load_plan(path):
    value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    partitions = value.get("partitions")
    if not isinstance(partitions, list) or not partitions:
        raise ValueError("plan must contain partitions")
    for row in partitions:
        if not row["partition"].startswith("2026-") or len(row["source_sha256"]) != 64:
            raise ValueError("invalid partition record")
    return value


def partition_digest(row):
    return hashlib.sha256(canonical_json(row)).hexdigest()


def build_index(plan):
    partitions = sorted(plan["partitions"], key=lambda row: row["partition"])
    set_hash = hashlib.sha256(b"\n".join(partition_digest(row).encode() for row in partitions)).hexdigest()
    return {
        "dataset": plan["dataset"],
        "base_generation": int(plan["base_generation"]),
        "partition_count": len(partitions),
        "total_objects": sum(int(row["object_count"]) for row in partitions),
        "total_bytes": sum(int(row["bytes"]) for row in partitions),
        "partitions": partitions,
        "partition_set_sha256": set_hash,
    }


def coordinate(args):
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    plan = load_plan(args.plan)
    state_dir = pathlib.Path(args.state_dir)
    events = state_dir / "partition-events"
    events.mkdir(parents=True, exist_ok=True)
    sequence = 0
    chain_head = "0" * 64
    with ExclusivePidfile(args.pidfile) as claim:
        while not stopping:
            row = plan["partitions"][sequence % len(plan["partitions"])]
            sequence += 1
            event = {
                "sequence": sequence,
                "partition": row["partition"],
                "source_sha256": row["source_sha256"],
                "partition_digest": partition_digest(row),
            }
            event_hash = hashlib.sha256(bytes.fromhex(chain_head) + canonical_json(event)).hexdigest()
            event["previous_chain_sha256"] = chain_head
            event["chain_sha256"] = event_hash
            chain_head = event_hash
            atomic_json(events / f"{sequence:05d}.json", event)
            atomic_json(state_dir / "progress.json", {
                "pid": os.getpid(),
                "start_ticks": proc_start_ticks(),
                "heartbeat_ns": time.time_ns(),
                "dispatch_seq": sequence,
                "last_partition": row["partition"],
                "chain_head_sha256": chain_head,
                "claim_dev": claim.inode[0],
                "claim_inode": claim.inode[1],
                "dataset": plan["dataset"],
            })
            time.sleep(args.interval)
    return 0


def materialize_once(args):
    plan = load_plan(args.plan)
    with ExclusivePidfile(args.pidfile) as claim:
        index = build_index(plan)
        output_dir = pathlib.Path(args.output_dir)
        index_path = output_dir / "snapshot-index.json"
        ledger_path = output_dir / "completion-ledger.json"
        atomic_json(index_path, index)
        ledger = {
            "request_id": plan["request_id"],
            "dataset": plan["dataset"],
            "base_generation": int(plan["base_generation"]),
            "plan_sha256": file_sha256(args.plan),
            "index_sha256": file_sha256(index_path),
            "partition_count": index["partition_count"],
            "total_objects": index["total_objects"],
            "total_bytes": index["total_bytes"],
            "partition_set_sha256": index["partition_set_sha256"],
            "claim": {
                "pidfile": str(pathlib.Path(args.pidfile)),
                "owner_pid": os.getpid(),
                "owner_start_ticks": proc_start_ticks(),
                "device": claim.inode[0],
                "inode": claim.inode[1],
                "protocol": "O_CREAT|O_EXCL",
            },
        }
        atomic_json(ledger_path, ledger)
        time.sleep(args.hold_seconds)
    print(f"SNAPSHOT_COMMITTED=1 REQUEST_ID={plan['request_id']} OUTPUT_DIR={args.output_dir}", flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(prog="snapshot-dispatch")
    sub = parser.add_subparsers(dest="command", required=True)
    coord = sub.add_parser("coordinate")
    coord.add_argument("--pidfile", required=True)
    coord.add_argument("--plan", required=True)
    coord.add_argument("--state-dir", required=True)
    coord.add_argument("--interval", type=float, default=0.2)
    one = sub.add_parser("materialize-once")
    one.add_argument("--pidfile", required=True)
    one.add_argument("--plan", required=True)
    one.add_argument("--output-dir", required=True)
    one.add_argument("--hold-seconds", type=float, default=2.2)
    args = parser.parse_args()
    return coordinate(args) if args.command == "coordinate" else materialize_once(args)


if __name__ == "__main__":
    raise SystemExit(main())
