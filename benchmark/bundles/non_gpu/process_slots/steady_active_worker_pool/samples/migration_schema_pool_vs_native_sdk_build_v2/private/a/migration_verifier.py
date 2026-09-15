#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
import multiprocessing as mp
import os
import signal
import sqlite3
import time
from pathlib import Path


def start_ticks(pid):
    return int(Path(f"/proc/{pid}/stat").read_text().split()[21])


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def set_name(value):
    try:
        ctypes.CDLL(None).prctl(15, value.encode(), 0, 0, 0)
    except OSError:
        pass


def verify_tenant(worker, migration_root, progress_root, stopped, pause):
    set_name(f"schema-check-{worker:02d}")
    scripts = sorted((migration_root / f"tenant-{worker:02d}").glob("*.sql"))
    cycle = 0
    while not stopped.is_set():
        connection = sqlite3.connect(":memory:")
        connection.execute("pragma foreign_keys=on")
        digest = hashlib.sha256()
        for script in scripts:
            sql = script.read_text(encoding="utf-8")
            digest.update(sql.encode())
            connection.executescript(sql)
        for index in range(24):
            connection.execute(
                "insert into accounts(account_id, name) values (?, ?)",
                (index + 1, f"tenant-{worker:02d}-account-{index:03d}"),
            )
            connection.execute(
                "insert into audit_events(event_id, account_id, payload) values (?, ?, ?)",
                (index + 1, index + 1, json.dumps({"worker": worker, "cycle": cycle, "event": index})),
            )
        integrity = connection.execute("pragma integrity_check").fetchone()[0]
        foreign_keys = connection.execute("pragma foreign_key_check").fetchall()
        schema = connection.execute(
            "select type, name, sql from sqlite_master where sql is not null order by type, name"
        ).fetchall()
        schema_hash = hashlib.sha256(json.dumps(schema, sort_keys=True).encode()).hexdigest()
        rows = connection.execute("select count(*) from audit_events").fetchone()[0]
        connection.close()
        if integrity != "ok" or foreign_keys or rows != 24:
            raise RuntimeError(f"tenant {worker} validation failed")
        cycle += 1
        atomic_json(progress_root / f"worker-{worker:02d}.json", {
            "worker": worker,
            "pid": os.getpid(),
            "start_ticks": start_ticks(os.getpid()),
            "cycle": cycle,
            "validated_migrations": len(scripts) * cycle,
            "progress_units": len(scripts) * cycle,
            "rows_checked": rows * cycle,
            "migration_digest": digest.hexdigest(),
            "schema_hash": schema_hash,
            "updated_at": time.time(),
        })
        stopped.wait(pause)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--migrations", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--cycle-pause", type=float, default=0.08)
    args = parser.parse_args()
    root = Path(args.state)
    progress_root = root / "progress"
    progress_root.mkdir(parents=True, exist_ok=True)
    stopped = mp.Event()
    normal_stop = {"value": False}

    def request_stop(_signum=None, _frame=None):
        normal_stop["value"] = True
        stopped.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    children = []
    for worker in range(args.workers):
        process = mp.Process(
            target=verify_tenant,
            args=(worker, Path(args.migrations), progress_root, stopped, args.cycle_pause),
            name=f"migration-validator-{worker:02d}",
        )
        process.start()
        children.append(process)
    roster = {
        "supervisor": {"pid": os.getpid(), "start_ticks": start_ticks(os.getpid())},
        "workers": [
            {"worker": worker, "pid": process.pid, "start_ticks": start_ticks(process.pid)}
            for worker, process in enumerate(children)
        ],
    }
    atomic_json(root / "roster.json", roster)
    ready_deadline = time.monotonic() + 20
    while time.monotonic() < ready_deadline and not stopped.is_set():
        if len(list(progress_root.glob("worker-*.json"))) == args.workers:
            break
        if any(not process.is_alive() for process in children):
            stopped.set()
            break
        time.sleep(0.02)
    while not stopped.is_set():
        if (root / "stop.request").exists():
            normal_stop["value"] = True
            stopped.set()
            break
        if any(not process.is_alive() for process in children):
            atomic_json(root / "health.json", {
                "healthy": False, "state": "failed", "reason": "worker_exited",
                "pid": os.getpid(), "start_ticks": roster["supervisor"]["start_ticks"],
            })
            stopped.set()
            break
        records = []
        for path in progress_root.glob("worker-*.json"):
            try:
                records.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        atomic_json(root / "health.json", {
            "healthy": len(records) == args.workers,
            "state": "running",
            "pid": os.getpid(),
            "start_ticks": roster["supervisor"]["start_ticks"],
            "workers": len(records),
            "total_cycles": sum(int(item["cycle"]) for item in records),
            "validated_migrations": sum(int(item["validated_migrations"]) for item in records),
            "progress_units": sum(int(item.get("progress_units", item.get("validated_migrations", 0))) for item in records),
            "rows_checked": sum(int(item["rows_checked"]) for item in records),
            "updated_at": time.time(),
        })
        time.sleep(0.04)
    stopped.set()
    for process in children:
        process.join(timeout=5)
    survivors = [process.pid for process in children if process.is_alive()]
    if survivors:
        for process in children:
            if process.is_alive():
                process.terminate()
        for process in children:
            process.join(timeout=2)
    records = []
    for path in progress_root.glob("worker-*.json"):
        try:
            records.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError):
            pass
    atomic_json(root / "health.json", {
        "healthy": False,
        "state": "stopped",
        "normal_stop": normal_stop["value"] and not survivors,
        "pid": os.getpid(),
        "start_ticks": roster["supervisor"]["start_ticks"],
        "workers": len(records),
        "total_cycles": sum(int(item["cycle"]) for item in records),
        "validated_migrations": sum(int(item["validated_migrations"]) for item in records),
        "progress_units": sum(int(item.get("progress_units", item.get("validated_migrations", 0))) for item in records),
        "rows_checked": sum(int(item["rows_checked"]) for item in records),
        "updated_at": time.time(),
    })


if __name__ == "__main__":
    main()
