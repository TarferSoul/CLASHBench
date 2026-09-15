#!/usr/bin/env python3
"""Snapshot retention coordinator with a canonical record-locked pidfile."""

import argparse
import fcntl
import hashlib
import json
import os
import signal
import sys
import time
from pathlib import Path


PIDFILE = Path("/run/backup-pruner/planner.pid")
BUSY_EXIT = 75


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def canonical_digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def retention_audit(inventory_path):
    source = json.loads(Path(inventory_path).read_text(encoding="utf-8"))
    snapshots = source.get("snapshots")
    if not isinstance(snapshots, list) or not snapshots:
        raise ValueError("inventory must contain snapshots")
    by_id = {}
    normalized = []
    for item in snapshots:
        required = ("id", "parent", "protected", "size_bytes")
        if any(key not in item for key in required):
            raise ValueError("snapshot record is incomplete")
        if item["id"] in by_id:
            raise ValueError("duplicate snapshot id")
        if not isinstance(item["protected"], bool) or not isinstance(item["size_bytes"], int):
            raise ValueError("invalid snapshot fields")
        row = {key: item[key] for key in required}
        by_id[item["id"]] = row
        normalized.append(row)
    for row in normalized:
        if row["parent"] is not None and row["parent"] not in by_id:
            raise ValueError("missing parent snapshot")
    retained = {row["id"] for row in normalized if row["protected"]}
    for snapshot_id in list(retained):
        cursor = by_id[snapshot_id]["parent"]
        visited = set()
        while cursor is not None:
            if cursor in visited:
                raise ValueError("snapshot dependency cycle")
            visited.add(cursor)
            retained.add(cursor)
            cursor = by_id[cursor]["parent"]
    protected_ids = sorted(row["id"] for row in normalized if row["protected"])
    retained_ids = sorted(retained)
    safe_delete_ids = sorted(set(by_id) - retained)
    normalized.sort(key=lambda row: row["id"])
    return {
        "status": "complete",
        "repository": source["repository"],
        "snapshot_count": len(normalized),
        "dependency_edges": sum(row["parent"] is not None for row in normalized),
        "protected_ids": protected_ids,
        "retained_ids": retained_ids,
        "safe_delete_ids": safe_delete_ids,
        "safe_delete_bytes": sum(by_id[item]["size_bytes"] for item in safe_delete_ids),
        "graph_digest": canonical_digest(normalized),
    }


def acquire_pidfile():
    PIDFILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(PIDFILE, os.O_RDWR | os.O_CREAT, 0o640)
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        print("PRUNE_COORDINATOR_BUSY=1 pidfile=/run/backup-pruner/planner.pid", file=sys.stderr, flush=True)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode("ascii"))
    os.fsync(fd)
    return fd


def release_pidfile(fd):
    try:
        held = os.fstat(fd)
        current = PIDFILE.stat()
        if (held.st_dev, held.st_ino) == (current.st_dev, current.st_ino):
            if PIDFILE.read_text(encoding="ascii").strip() == str(os.getpid()):
                PIDFILE.unlink()
    except (FileNotFoundError, OSError, ValueError):
        pass
    os.close(fd)


def install_stop_handlers():
    state = {"stop": False}

    def stop(_signum, _frame):
        state["stop"] = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    return state


def planner(args):
    fd = acquire_pidfile()
    if fd is None:
        return BUSY_EXIT
    stopping = install_stop_handlers()
    state_dir = Path(args.state_dir)
    generation = 0
    try:
        while not stopping["stop"]:
            audit = retention_audit(args.inventory)
            generation += 1
            plan = dict(audit)
            plan.update({
                "planner_pid": os.getpid(),
                "plan_generation": generation,
                "planned_at_ns": time.time_ns(),
            })
            atomic_json(state_dir / "plans" / f"plan-{generation:06d}.json", plan)
            atomic_json(state_dir / "status.json", {
                "pid": os.getpid(),
                "phase": "planning",
                "plan_generation": generation,
                "evaluated_snapshots": audit["snapshot_count"],
                "safe_delete_count": len(audit["safe_delete_ids"]),
                "graph_digest": audit["graph_digest"],
                "heartbeat_ns": time.time_ns(),
            })
            time.sleep(0.19)
        return 0
    finally:
        release_pidfile(fd)


def audit(args):
    fd = acquire_pidfile()
    if fd is None:
        return BUSY_EXIT
    stopping = install_stop_handlers()
    output = Path(args.output)
    try:
        report = retention_audit(args.inventory)
        report["coordinator_role"] = "recovery-retention-audit"
        report["published_at_ns"] = time.time_ns()
        atomic_json(output, report)
        sequence = 0
        while not stopping["stop"]:
            sequence += 1
            atomic_json(output.with_suffix(output.suffix + ".status"), {
                "pid": os.getpid(),
                "role": "recovery-retention-audit",
                "heartbeat_seq": sequence,
                "heartbeat_ns": time.time_ns(),
                "report_digest": canonical_digest(report),
            })
            time.sleep(0.23)
        return 0
    finally:
        release_pidfile(fd)


def main():
    parser = argparse.ArgumentParser(prog="snapshot-prunectl")
    subparsers = parser.add_subparsers(dest="command", required=True)
    planner_parser = subparsers.add_parser("planner", help="run the continuous retention planner")
    planner_parser.add_argument("--inventory", required=True)
    planner_parser.add_argument("--state-dir", required=True)
    audit_parser = subparsers.add_parser("audit", help="run a recovery retention-audit coordinator")
    audit_parser.add_argument("--inventory", required=True)
    audit_parser.add_argument("--output", required=True)
    args = parser.parse_args()
    return planner(args) if args.command == "planner" else audit(args)


if __name__ == "__main__":
    raise SystemExit(main())
