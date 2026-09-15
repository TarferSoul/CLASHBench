#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import sys
import time


stop_requested = False


def request_stop(signum, _frame):
    global stop_requested
    stop_requested = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def proc_start_ticks(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21])


def write_progress(path, phase, processed, total, current, started_at):
    atomic_json(
        path,
        {
            "schema_version": 1,
            "pid": os.getpid(),
            "ppid": os.getppid(),
            "pgid": os.getpgrp(),
            "start_ticks": proc_start_ticks(os.getpid()),
            "phase": phase,
            "processed": processed,
            "total": total,
            "current": current,
            "started_at": started_at,
            "heartbeat_unix": time.time(),
        },
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock-fd", type=int, required=True)
    parser.add_argument("--lock-path", required=True)
    parser.add_argument("--expected-uid", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--stage-root", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--record-delay", type=float, required=True)
    args = parser.parse_args()

    if os.getuid() != args.expected_uid or args.expected_uid <= 0:
        print("identity mismatch for catalog worker", file=sys.stderr)
        return 90

    lock_stat = os.stat(args.lock_path)
    fd_stat = os.fstat(args.lock_fd)
    if (lock_stat.st_dev, lock_stat.st_ino) != (fd_stat.st_dev, fd_stat.st_ino):
        print("inherited descriptor does not name canonical lock inode", file=sys.stderr)
        return 91
    try:
        fcntl.flock(args.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        print(f"inherited open file description lost its lock: {exc}", file=sys.stderr)
        return 92

    state_dir = pathlib.Path(args.state_dir)
    input_dir = pathlib.Path(args.input_dir)
    stage_dir = pathlib.Path(args.stage_root) / f"catalog-{os.getpid()}"
    progress_path = state_dir / "progress.json"
    identity_path = state_dir / "worker_identity.json"
    stage_dir.mkdir(parents=True, exist_ok=False)
    manifest_path = stage_dir / "catalog.entries.jsonl"
    inputs = sorted(input_dir.glob("artifact-*.json"))
    if not inputs:
        print("catalog source is empty", file=sys.stderr)
        return 93

    started_at = time.time()
    identity = {
        "schema_version": 1,
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "pgid": os.getpgrp(),
        "start_ticks": proc_start_ticks(os.getpid()),
        "lock_fd": args.lock_fd,
        "lock_device": lock_stat.st_dev,
        "lock_inode": lock_stat.st_ino,
        "stage_path": str(stage_dir),
        "stage_device": stage_dir.stat().st_dev,
        "stage_inode": stage_dir.stat().st_ino,
    }
    atomic_json(identity_path, identity)
    write_progress(progress_path, "scan", 0, len(inputs), "", started_at)

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    entries = []
    with manifest_path.open("w") as manifest:
        for index, source in enumerate(inputs, start=1):
            if stop_requested:
                write_progress(
                    progress_path,
                    "stopped",
                    index - 1,
                    len(inputs),
                    source.name,
                    started_at,
                )
                print(f"CATALOG_REBUILD_STOPPED processed={index - 1}", flush=True)
                return 143
            payload = source.read_bytes()
            record = json.loads(payload)
            if record.get("artifact_id") != source.stem:
                print(f"invalid artifact identity in {source}", file=sys.stderr)
                return 94
            entry = {
                "artifact_id": record["artifact_id"],
                "model_family": record["model_family"],
                "metadata_sha256": hashlib.sha256(payload).hexdigest(),
                "bytes": len(payload),
            }
            manifest.write(json.dumps(entry, sort_keys=True) + "\n")
            manifest.flush()
            entries.append(entry)
            phase = "hash" if index < len(inputs) - 3 else "validate"
            write_progress(progress_path, phase, index, len(inputs), source.name, started_at)
            if index == 1 or index % 25 == 0:
                print(
                    f"CATALOG_REBUILD_PROGRESS phase={phase} processed={index} total={len(inputs)}",
                    flush=True,
                )
            time.sleep(args.record_delay)
        os.fsync(manifest.fileno())

    write_progress(progress_path, "atomic_publish", len(inputs), len(inputs), "", started_at)
    catalog_path = pathlib.Path(args.catalog)
    current = json.loads(catalog_path.read_text())
    next_catalog = {
        "schema_version": 1,
        "generation": int(current.get("generation", 0)) + 1,
        "published_by": "catalog-integrity-rebuild",
        "entries": entries,
        "releases": current.get("releases", []),
    }
    atomic_json(catalog_path, next_catalog)
    atomic_json(stage_dir / "publish_receipt.json", {
        "generation": next_catalog["generation"],
        "entry_count": len(entries),
        "catalog": str(catalog_path),
    })
    write_progress(progress_path, "complete", len(inputs), len(inputs), "", started_at)
    print(f"CATALOG_REBUILD_COMPLETE entries={len(entries)} generation={next_catalog['generation']}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
