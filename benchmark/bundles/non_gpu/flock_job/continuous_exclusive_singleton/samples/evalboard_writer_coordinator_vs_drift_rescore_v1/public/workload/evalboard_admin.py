#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import math
import os
import pathlib
import sqlite3
import sys
import time


DEFAULT_LOCK = pathlib.Path("/run/lock/evalboard-writer.lock")
DEFAULT_DB = pathlib.Path("/work/evalboard/results.sqlite")
DEFAULT_LEADERBOARD = pathlib.Path("/work/evalboard/leaderboard_summary.json")
DEFAULT_OUTPUT_DIR = pathlib.Path("/work/eval_rescore")
DEFAULT_TIMEOUT = 2.0


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def atomic_json(path, payload, mode=0o644):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def file_sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path):
    records = []
    with pathlib.Path(path).open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{lineno}: invalid JSON: {exc}") from exc
    return records


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


def validate_result_record(record, source):
    required = ("run_id", "suite", "model", "split", "exact_match", "latency_ms")
    missing = [key for key in required if key not in record]
    if missing:
        raise ValueError(f"{source}: missing fields: {','.join(missing)}")
    return {
        "run_id": str(record["run_id"]),
        "suite": str(record["suite"]),
        "model": str(record["model"]),
        "split": str(record["split"]),
        "exact_match": float(record["exact_match"]),
        "latency_ms": float(record["latency_ms"]),
    }


def load_baseline(conn, baseline_path):
    ensure_schema(conn)
    inserted = 0
    for raw in read_jsonl(baseline_path):
        rec = validate_result_record(raw, str(baseline_path))
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
                "baseline-fixture",
                utc_now(),
            ),
        )
        inserted += cur.rowcount
    set_metadata(conn, "db_generation", max(metadata_int(conn, "db_generation"), 1))
    set_metadata(conn, "rescore_generation", metadata_int(conn, "rescore_generation"))
    conn.commit()
    return inserted


def percentile95(values):
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    index = max(0, math.ceil(0.95 * len(ordered)) - 1)
    return ordered[index]


def build_leaderboard(conn, path):
    suites = []
    for suite, count, avg_exact, avg_latency in conn.execute(
        """
        SELECT suite, COUNT(*), AVG(exact_match), AVG(latency_ms)
        FROM result_records
        GROUP BY suite
        ORDER BY suite
        """
    ):
        latencies = [
            row[0]
            for row in conn.execute(
                "SELECT latency_ms FROM result_records WHERE suite = ? ORDER BY latency_ms",
                (suite,),
            )
        ]
        suites.append(
            {
                "suite": suite,
                "run_count": int(count),
                "mean_exact_match": round(float(avg_exact), 4),
                "mean_latency_ms": round(float(avg_latency), 2),
                "latency_p95_ms": round(percentile95(latencies), 2),
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


def open_writer_lock(path, timeout):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        os.chmod(path, 0o666)
    except PermissionError:
        pass
    deadline = time.monotonic() + float(timeout)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise TimeoutError(f"evalboard writer lock busy: {path} timeout={timeout}")
            time.sleep(0.05)


def lock_identity(path):
    stat = os.stat(path)
    return {
        "lock_path": str(path),
        "lock_device_major": os.major(stat.st_dev),
        "lock_device_minor": os.minor(stat.st_dev),
        "lock_inode": stat.st_ino,
    }


def init_state(args):
    pathlib.Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(args.db)
    try:
        inserted = load_baseline(conn, args.baseline)
        build_leaderboard(conn, args.leaderboard)
    finally:
        conn.close()
    try:
        os.chmod(args.db, 0o666)
    except PermissionError:
        pass
    print(json.dumps({"initialized": True, "baseline_records": inserted, "db": args.db}, sort_keys=True))
    return 0


def load_rescore_rows(path, suite):
    rows = []
    for raw in read_jsonl(path):
        required = ("example_id", "suite", "candidate_run_id", "old_exact_match", "new_exact_match", "latency_ms")
        missing = [key for key in required if key not in raw]
        if missing:
            raise ValueError(f"{path}: missing rescore fields: {','.join(missing)}")
        if str(raw["suite"]) != suite:
            raise ValueError(f"{path}: unexpected suite {raw['suite']!r}")
        rows.append(
            {
                "example_id": str(raw["example_id"]),
                "suite": str(raw["suite"]),
                "candidate_run_id": str(raw["candidate_run_id"]),
                "old_exact_match": float(raw["old_exact_match"]),
                "new_exact_match": float(raw["new_exact_match"]),
                "latency_ms": float(raw["latency_ms"]),
            }
        )
    if not rows:
        raise ValueError(f"{path}: no rescore rows for {suite}")
    return rows


def run_rescore(args):
    if not args.once:
        print("rescore requires --once", file=sys.stderr)
        return 2
    try:
        lock_fd = open_writer_lock(args.lock, args.lock_timeout)
    except TimeoutError as exc:
        print(str(exc), file=sys.stderr)
        return 75

    try:
        rows = load_rescore_rows(args.input, args.suite)
        input_hash = file_sha256(args.input)
        conn = sqlite3.connect(args.db)
        try:
            ensure_schema(conn)
            generation = metadata_int(conn, "rescore_generation") + 1
            exact_delta = sum(row["new_exact_match"] - row["old_exact_match"] for row in rows) / len(rows)
            latency_p95 = percentile95([row["latency_ms"] for row in rows])
            conn.execute(
                """
                INSERT INTO rescore_runs
                  (rescore_generation, suite, example_count, exact_match_delta,
                   latency_p95_ms, input_sha256, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    generation,
                    args.suite,
                    len(rows),
                    round(exact_delta, 6),
                    round(latency_p95, 2),
                    input_hash,
                    utc_now(),
                ),
            )
            set_metadata(conn, "rescore_generation", generation)
            conn.commit()
            build_leaderboard(conn, args.leaderboard)
        finally:
            conn.close()

        output_dir = pathlib.Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        candidate_run_id = rows[0]["candidate_run_id"]
        summary = {
            "suite": args.suite,
            "rescore_generation": generation,
            "example_count": len(rows),
            "exact_match_delta": round(exact_delta, 6),
            "latency_p95_ms": round(latency_p95, 2),
            "candidate_run_id": candidate_run_id,
            "input_sha256": input_hash,
            "source_shard": str(pathlib.Path(args.input).resolve()),
            "completed_at": utc_now(),
            **lock_identity(args.lock),
        }
        promotion = {
            "suite": args.suite,
            "candidate_run_id": candidate_run_id,
            "rescore_generation": generation,
            "promote": summary["exact_match_delta"] >= 0.02 and summary["latency_p95_ms"] <= 200,
            "summary_path": str(output_dir / "summary.json"),
            "created_at": utc_now(),
        }
        atomic_json(output_dir / "summary.json", summary)
        atomic_json(output_dir / "promotion_candidate.json", promotion)
        print(json.dumps(summary, sort_keys=True))
        return 0
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="evalboard-admin")
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init-state")
    init.add_argument("--baseline", required=True)
    init.add_argument("--db", default=str(DEFAULT_DB))
    init.add_argument("--leaderboard", default=str(DEFAULT_LEADERBOARD))

    rescore = sub.add_parser("rescore")
    rescore.add_argument("--once", action="store_true")
    rescore.add_argument("--suite", required=True)
    rescore.add_argument("--input", required=True)
    rescore.add_argument("--db", default=str(DEFAULT_DB))
    rescore.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR))
    rescore.add_argument("--leaderboard", default=str(DEFAULT_LEADERBOARD))
    rescore.add_argument("--lock-timeout", type=float, default=DEFAULT_TIMEOUT)
    rescore.set_defaults(lock=str(DEFAULT_LOCK))

    args = parser.parse_args(argv)
    if args.command == "init-state":
        return init_state(args)
    if args.command == "rescore":
        return run_rescore(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
