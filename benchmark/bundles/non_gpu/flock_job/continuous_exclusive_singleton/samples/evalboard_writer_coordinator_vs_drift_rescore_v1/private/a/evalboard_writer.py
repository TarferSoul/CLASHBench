#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pathlib
import signal
import shutil
import sqlite3
import sys
import time


STOP = False


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_text(path, text, mode=0o644):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def atomic_json(path, value, mode=0o644):
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n", mode=mode)


def proc_start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])


def lock_identity(path):
    stat = os.stat(path)
    return {
        "lock_path": str(path),
        "lock_device_major": os.major(stat.st_dev),
        "lock_device_minor": os.minor(stat.st_dev),
        "lock_inode": stat.st_ino,
    }


def open_lifetime_lock(path):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        os.chmod(path, 0o666)
    except PermissionError:
        pass
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def ensure_schema(conn):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS result_records (
          run_id TEXT PRIMARY KEY,
          suite TEXT NOT NULL,
          model TEXT NOT NULL,
          split TEXT NOT NULL,
          exact_match REAL NOT NULL,
          latency_ms REAL NOT NULL,
          source TEXT NOT NULL,
          committed_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rescore_runs (
          rescore_generation INTEGER PRIMARY KEY,
          suite TEXT NOT NULL,
          example_count INTEGER NOT NULL,
          exact_match_delta REAL NOT NULL,
          latency_p95_ms REAL NOT NULL,
          input_sha256 TEXT NOT NULL,
          created_at TEXT NOT NULL
        );
        """
    )
    conn.commit()


def metadata_int(conn, key, default=0):
    row = conn.execute("SELECT value FROM metadata WHERE key = ?", (key,)).fetchone()
    if not row:
        return default
    try:
        return int(row[0])
    except ValueError:
        return default


def set_metadata(conn, key, value):
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, str(value)),
    )


def read_jsonl(path):
    rows = []
    with pathlib.Path(path).open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{lineno}: invalid JSON: {exc}") from exc
    return rows


def validate_record(record, path):
    required = ("run_id", "suite", "model", "split", "exact_match", "latency_ms")
    missing = [key for key in required if key not in record]
    if missing:
        raise ValueError(f"{path}: missing fields: {','.join(missing)}")
    return {
        "run_id": str(record["run_id"]),
        "suite": str(record["suite"]),
        "model": str(record["model"]),
        "split": str(record["split"]),
        "exact_match": float(record["exact_match"]),
        "latency_ms": float(record["latency_ms"]),
    }


def refresh_leaderboard(conn, path):
    suites = []
    for suite, count, avg_exact, max_latency in conn.execute(
        """
        SELECT suite, COUNT(*), AVG(exact_match), MAX(latency_ms)
        FROM result_records
        GROUP BY suite
        ORDER BY suite
        """
    ):
        suites.append(
            {
                "suite": suite,
                "run_count": int(count),
                "mean_exact_match": round(float(avg_exact), 4),
                "max_latency_ms": round(float(max_latency), 2),
            }
        )
    atomic_json(
        path,
        {
            "generated_at": utc_now(),
            "db_generation": metadata_int(conn, "db_generation"),
            "rescore_generation": metadata_int(conn, "rescore_generation"),
            "suites": suites,
        },
    )


def status_payload(args, heartbeat, phase, processed_shards, accepted_records, current_suite, last_run):
    db_generation = 0
    try:
        conn = sqlite3.connect(args.db)
        try:
            db_generation = metadata_int(conn, "db_generation")
        finally:
            conn.close()
    except sqlite3.Error:
        db_generation = -1
    payload = {
        "pid": os.getpid(),
        "start_time": proc_start_time(os.getpid()),
        "heartbeat_seq": heartbeat,
        "processed_shards": processed_shards,
        "accepted_records": accepted_records,
        "db_generation": db_generation,
        "phase": phase,
        "current_suite": current_suite,
        "last_committed_run": last_run,
        "updated_at": utc_now(),
    }
    payload.update(lock_identity(args.lock))
    return payload


def write_status(args, heartbeat, phase, processed_shards, accepted_records, current_suite, last_run):
    atomic_json(
        args.status,
        status_payload(args, heartbeat, phase, processed_shards, accepted_records, current_suite, last_run),
    )


def process_shard(conn, path, args, counters):
    rows = read_jsonl(path)
    source = pathlib.Path(path).name
    accepted = 0
    current_suite = ""
    last_run = counters["last_committed_run"]
    for raw in rows:
        if STOP:
            break
        rec = validate_record(raw, path)
        current_suite = rec["suite"]
        cur = conn.execute(
            """
            INSERT OR IGNORE INTO result_records
              (run_id, suite, model, split, exact_match, latency_ms, source, committed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                rec["run_id"],
                rec["suite"],
                rec["model"],
                rec["split"],
                rec["exact_match"],
                rec["latency_ms"],
                source,
                utc_now(),
            ),
        )
        if cur.rowcount:
            accepted += 1
            counters["accepted_records"] += 1
            last_run = rec["run_id"]
            counters["last_committed_run"] = last_run
            set_metadata(conn, "db_generation", metadata_int(conn, "db_generation") + 1)
        conn.commit()
        counters["heartbeat_seq"] += 1
        write_status(
            args,
            counters["heartbeat_seq"],
            "ingesting",
            counters["processed_shards"],
            counters["accepted_records"],
            current_suite,
            last_run,
        )
        time.sleep(args.record_interval)
    refresh_leaderboard(conn, args.leaderboard)
    return accepted, current_suite, last_run


def handle_stop(_signum, _frame):
    global STOP
    STOP = True


def run_controller(args):
    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    pathlib.Path(args.status).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.incoming).mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.processed).mkdir(parents=True, exist_ok=True)
    atomic_text(args.pid_file, f"{os.getpid()}\n")

    lock_fd = open_lifetime_lock(args.lock)
    conn = sqlite3.connect(args.db)
    counters = {
        "heartbeat_seq": 0,
        "processed_shards": 0,
        "accepted_records": 0,
        "last_committed_run": "",
    }
    current_suite = ""
    try:
        ensure_schema(conn)
        while not STOP:
            counters["heartbeat_seq"] += 1
            write_status(
                args,
                counters["heartbeat_seq"],
                "scanning",
                counters["processed_shards"],
                counters["accepted_records"],
                current_suite,
                counters["last_committed_run"],
            )
            shards = sorted(path for path in pathlib.Path(args.incoming).glob("*.jsonl") if path.is_file())
            if not shards:
                counters["heartbeat_seq"] += 1
                write_status(
                    args,
                    counters["heartbeat_seq"],
                    "idle",
                    counters["processed_shards"],
                    counters["accepted_records"],
                    current_suite,
                    counters["last_committed_run"],
                )
                time.sleep(args.poll_interval)
                continue
            for shard in shards:
                if STOP:
                    break
                accepted, current_suite, _ = process_shard(conn, shard, args, counters)
                counters["processed_shards"] += 1
                target = pathlib.Path(args.processed) / shard.name
                shutil.move(str(shard), target)
                counters["heartbeat_seq"] += 1
                write_status(
                    args,
                    counters["heartbeat_seq"],
                    "committed",
                    counters["processed_shards"],
                    counters["accepted_records"],
                    current_suite,
                    counters["last_committed_run"],
                )
                time.sleep(args.poll_interval)
                if accepted == 0:
                    continue
        counters["heartbeat_seq"] += 1
        write_status(
            args,
            counters["heartbeat_seq"],
            "stopping",
            counters["processed_shards"],
            counters["accepted_records"],
            current_suite,
            counters["last_committed_run"],
        )
    finally:
        conn.close()
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="evalboard-writer")
    parser.add_argument("--lock", default="/run/lock/evalboard-writer.lock")
    parser.add_argument("--status", default="/run/evalboard/status.json")
    parser.add_argument("--pid-file", default="/run/evalboard/coordinator.pid")
    parser.add_argument("--db", default="/work/evalboard/results.sqlite")
    parser.add_argument("--leaderboard", default="/work/evalboard/leaderboard_summary.json")
    parser.add_argument("--incoming", default="/work/evalboard/incoming")
    parser.add_argument("--processed", default="/work/evalboard/processed")
    parser.add_argument("--poll-interval", type=float, default=0.20)
    parser.add_argument("--record-interval", type=float, default=0.04)
    args = parser.parse_args(argv)
    run_controller(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
