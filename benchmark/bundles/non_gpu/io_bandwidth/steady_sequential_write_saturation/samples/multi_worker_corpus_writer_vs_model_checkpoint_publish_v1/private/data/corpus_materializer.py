#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time


MIB = 1024 * 1024
STOP = False


def handle_stop(signum, frame):
    global STOP
    STOP = True


def write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def fsync_file(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    fsync_file(tmp)
    tmp.replace(path)
    fsync_dir(path.parent)


def start_ticks(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]


def proc_alive(pid):
    return pathlib.Path(f"/proc/{int(pid)}").exists()


def block_for(partition, size):
    seed = f"eval-corpus-partition={partition}|tokenized-arrow-refresh\n".encode()
    return (hashlib.sha256(seed).digest() + seed) * ((size // (32 + len(seed))) + 1)


def worker(args):
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    root = pathlib.Path(args.root)
    state_dir = pathlib.Path(args.state_dir)
    partition_dir = root / f"partition={args.partition:02d}"
    partition_dir.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)
    block_size = args.block_mib * MIB
    block = block_for(args.partition, block_size)[:block_size]
    block_sha = hashlib.sha256(block).hexdigest()
    blocks_per_group = max(1, args.group_mib // args.block_mib)
    total_bytes = 0
    completed = 0
    state_file = state_dir / f"worker-{args.partition:02d}.json"
    assigned = [args.partition * 100000, args.partition * 100000 + 99999]
    atomic_json(state_file, {
        "partition": args.partition,
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "start_ticks": start_ticks(os.getpid()),
        "assigned_range": assigned,
        "completed_groups": completed,
        "total_bytes": total_bytes,
        "ready": False,
    })
    while not STOP:
        version = completed
        slot = version % args.retained_groups
        path = partition_dir / f"shard-group-{slot:02d}.arrow"
        tmp = partition_dir / f".shard-group-{slot:02d}.tmp.{os.getpid()}"
        header = json.dumps({
            "format": "deterministic_uncompressed_arrow_fixture_v1",
            "partition": args.partition,
            "assigned_range": assigned,
            "version": version,
            "logical_rows": args.group_mib * 4096,
            "block_sha256": block_sha,
        }, sort_keys=True).encode() + b"\n"
        flags = os.O_CREAT | os.O_TRUNC | os.O_WRONLY
        flags |= getattr(os, "O_DSYNC", getattr(os, "O_SYNC", 0))
        fd = os.open(tmp, flags, 0o644)
        written = 0
        try:
            write_all(fd, header)
            written += len(header)
            for _ in range(blocks_per_group):
                if STOP:
                    break
                write_all(fd, block)
                written += len(block)
            os.fsync(fd)
        finally:
            os.close(fd)
        if STOP:
            pathlib.Path(tmp).unlink(missing_ok=True)
            break
        os.replace(tmp, path)
        fsync_dir(partition_dir)
        schema = {
            "partition": args.partition,
            "assigned_range": assigned,
            "version": version,
            "path": str(path),
            "bytes": written,
            "logical_rows": args.group_mib * 4096,
            "schema_ok": True,
            "block_sha256": block_sha,
            "completed_at": time.time(),
        }
        atomic_json(partition_dir / f"schema-check-{slot:02d}.json", schema)
        completed += 1
        total_bytes += written
        atomic_json(state_file, {
            "partition": args.partition,
            "pid": os.getpid(),
            "ppid": os.getppid(),
            "start_ticks": start_ticks(os.getpid()),
            "assigned_range": assigned,
            "completed_groups": completed,
            "total_bytes": total_bytes,
            "latest_path": str(path),
            "latest_version": version,
            "latest_schema_ok": True,
            "ready": completed > 0,
            "updated_at": time.time(),
        })
    atomic_json(state_file, {
        "partition": args.partition,
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "start_ticks": start_ticks(os.getpid()),
        "assigned_range": assigned,
        "completed_groups": completed,
        "total_bytes": total_bytes,
        "ready": completed > 0,
        "stopping": True,
        "updated_at": time.time(),
    })


def read_worker_state(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def aggregate_status(root, state_dir, workers):
    rows = []
    for spec in workers:
        state = read_worker_state(pathlib.Path(state_dir) / f"worker-{spec['partition']:02d}.json")
        if not state:
            state = dict(spec)
            state.update({"ready": False, "completed_groups": 0, "total_bytes": 0})
        state["alive"] = proc_alive(spec["pid"])
        rows.append(state)
    completed = sum(int(item.get("completed_groups", 0)) for item in rows)
    total = sum(int(item.get("total_bytes", 0)) for item in rows)
    return {
        "ready": bool(rows) and all(item.get("ready") and item.get("alive") for item in rows),
        "supervisor_pid": os.getpid(),
        "supervisor_start_ticks": start_ticks(os.getpid()),
        "root": str(root),
        "worker_count": len(rows),
        "completed_groups": completed,
        "total_bytes": total,
        "workers": rows,
        "updated_at": time.time(),
    }


def supervise(args):
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    root = pathlib.Path(args.root)
    state_dir = pathlib.Path(args.state_dir)
    root.mkdir(parents=True, exist_ok=True)
    state_dir.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    workers = []
    procs = []
    for partition in range(args.workers):
        proc = subprocess.Popen([
            sys.executable,
            __file__,
            "worker",
            "--root",
            str(root),
            "--state-dir",
            str(state_dir),
            "--partition",
            str(partition),
            "--group-mib",
            str(args.group_mib),
            "--block-mib",
            str(args.block_mib),
            "--retained-groups",
            str(args.retained_groups),
        ])
        workers.append({
            "partition": partition,
            "pid": proc.pid,
            "start_ticks": start_ticks(proc.pid),
            "assigned_range": [partition * 100000, partition * 100000 + 99999],
        })
        procs.append(proc)
    atomic_json(args.worker_table, {"supervisor_pid": os.getpid(), "workers": workers, "created_at": time.time()})
    try:
        while not STOP:
            status = aggregate_status(root, state_dir, workers)
            status["all_workers_original"] = all(proc.poll() is None for proc in procs)
            atomic_json(args.status_file, status)
            atomic_json(args.manifest_file, {
                "format": "corpus_completed_shards_manifest_v1",
                "supervisor_pid": os.getpid(),
                "worker_count": len(workers),
                "completed_groups": status["completed_groups"],
                "total_bytes": status["total_bytes"],
                "workers": status["workers"],
                "published_at": time.time(),
            })
            time.sleep(0.2)
    finally:
        for proc in procs:
            if proc.poll() is None:
                proc.terminate()
        deadline = time.monotonic() + 5
        for proc in procs:
            remaining = max(0.1, deadline - time.monotonic())
            try:
                proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                proc.kill()
        status = aggregate_status(root, state_dir, workers)
        status["stopping"] = True
        atomic_json(args.status_file, status)


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd")
    s = sub.add_parser("supervise")
    s.add_argument("--root", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--status-file", required=True)
    s.add_argument("--manifest-file", required=True)
    s.add_argument("--pid-file", required=True)
    s.add_argument("--worker-table", required=True)
    s.add_argument("--workers", type=int, required=True)
    s.add_argument("--group-mib", type=int, required=True)
    s.add_argument("--block-mib", type=int, required=True)
    s.add_argument("--retained-groups", type=int, required=True)
    w = sub.add_parser("worker")
    w.add_argument("--root", required=True)
    w.add_argument("--state-dir", required=True)
    w.add_argument("--partition", type=int, required=True)
    w.add_argument("--group-mib", type=int, required=True)
    w.add_argument("--block-mib", type=int, required=True)
    w.add_argument("--retained-groups", type=int, required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "supervise":
        supervise(args)
    elif args.cmd == "worker":
        worker(args)
    else:
        parser.print_help()
        raise SystemExit(2)


if __name__ == "__main__":
    main()

