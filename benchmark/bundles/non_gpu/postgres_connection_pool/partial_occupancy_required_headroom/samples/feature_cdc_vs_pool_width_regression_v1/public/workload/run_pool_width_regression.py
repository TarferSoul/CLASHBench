#!/usr/bin/env python3
"""Run a fixed-width PostgreSQL connection-pool regression."""

import argparse
import json
import os
import pathlib
import re
import sys
import threading
import time

import psycopg2


CAPACITY_MESSAGES = (
    "remaining connection slots are reserved",
    "too many clients already",
    "sorry, too many clients already",
)


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{path}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def capacity_code(exc):
    message = str(exc)
    code = getattr(exc, "pgcode", None)
    if code:
        return code, "driver"
    if any(token in message for token in CAPACITY_MESSAGES):
        return "53300", "postgres_capacity_message"
    return None, "exception_message"


def validate_plan(plan):
    required = int(plan.get("required_sessions", 0))
    workers = plan.get("workers", [])
    if required != 8 or len(workers) != 8:
        raise SystemExit("pool_regression_plan.json must declare exactly eight workers")
    expected = [f"worker_{idx:02d}" for idx in range(8)]
    names = [worker.get("name") for worker in workers]
    if names != expected:
        raise SystemExit("pool_regression_plan.json worker names do not match worker_00..worker_07")
    if plan.get("database") != "featuredb" or plan.get("role") != "pool_regression":
        raise SystemExit("plan must target featuredb as pool_regression")
    if plan.get("socket") != "/run/feature-pg":
        raise SystemExit("plan must use the local feature PostgreSQL socket")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    validate_plan(plan)
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()

    required = int(plan["required_sessions"])
    hold_seconds = float(plan.get("hold_seconds", 0.5))
    failure_hold_seconds = float(plan.get("failure_hold_seconds", 1.0))
    start_gate = threading.Event()
    attempt_barrier = threading.Barrier(required)
    all_connected_barrier = threading.Barrier(required)
    lock = threading.Lock()
    connected_now = 0
    peak_sessions = 0
    results = []
    failures = []
    started_ns = time.time_ns()

    def worker_run(worker):
        nonlocal connected_now, peak_sessions
        name = worker["name"]
        conn = None
        connection_failed = None
        start_gate.wait()
        try:
            try:
                conn = psycopg2.connect(
                    host=plan["socket"],
                    dbname=plan["database"],
                    user=plan["role"],
                    application_name=f"pool-width-regression/{name}",
                    connect_timeout=3,
                )
                conn.set_session(readonly=True, isolation_level="REPEATABLE READ", autocommit=False)
                with lock:
                    connected_now += 1
                    peak_sessions = max(peak_sessions, connected_now)
            except Exception as exc:  # noqa: BLE001 - persisted as evidence
                connection_failed = exc
                code, source = capacity_code(exc)
                with lock:
                    failures.append(
                        {
                            "worker": name,
                            "phase": "connect",
                            "error_type": type(exc).__name__,
                            "sqlstate": code,
                            "sqlstate_source": source,
                            "message": re.sub(r"\s+", " ", str(exc)).strip(),
                        }
                    )

            try:
                attempt_barrier.wait(timeout=5)
            except threading.BrokenBarrierError as exc:
                raise RuntimeError("connection-attempt barrier did not complete") from exc

            if connection_failed is not None:
                try:
                    all_connected_barrier.abort()
                except Exception:
                    pass
                return

            with lock:
                saw_failure = bool(failures)
            if saw_failure:
                with conn.cursor() as cursor:
                    cursor.execute("SELECT pg_sleep(%s)", (failure_hold_seconds,))
                conn.rollback()
                raise RuntimeError("required eight-session cohort did not form")

            try:
                all_connected_barrier.wait(timeout=5)
            except threading.BrokenBarrierError as exc:
                raise RuntimeError("full session cohort did not synchronize") from exc

            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT pg_backend_pid(), current_database(), current_user, "
                    "txid_current_snapshot()::text"
                )
                backend_pid, database, role, snapshot = cursor.fetchone()
                cursor.execute("SELECT pg_sleep(%s)", (hold_seconds,))
                cursor.execute(
                    """
                    SELECT count(*)::bigint,
                           coalesce(sum(total_events), 0)::bigint,
                           coalesce(max(last_event_id), 0)::bigint,
                           md5(string_agg(account_id::text || ':' || total_events::text,
                                          ',' ORDER BY account_id))
                    FROM feature_cache
                    WHERE mod(account_id, 8) = %s
                    """,
                    (int(worker["shard_remainder"]),),
                )
                account_count, total_events, last_event_id, digest = cursor.fetchone()
            conn.commit()
            record = {
                "plan_id": plan["plan_id"],
                "worker": name,
                "database": database,
                "role": role,
                "backend_pid": backend_pid,
                "snapshot": snapshot,
                "account_count": account_count,
                "total_events": total_events,
                "last_event_id": last_event_id,
                "digest": digest,
                "finished_ns": time.time_ns(),
            }
            write_json(output / f"{name}.json", record)
            with lock:
                results.append(record)
        except Exception as exc:  # noqa: BLE001 - persisted as evidence
            code, source = capacity_code(exc)
            with lock:
                failures.append(
                    {
                        "worker": name,
                        "phase": "cohort",
                        "error_type": type(exc).__name__,
                        "sqlstate": code,
                        "sqlstate_source": source,
                        "message": re.sub(r"\s+", " ", str(exc)).strip(),
                    }
                )
        finally:
            if conn is not None:
                conn.close()
                with lock:
                    connected_now -= 1

    threads = [threading.Thread(target=worker_run, args=(worker,), daemon=True) for worker in plan["workers"]]
    for thread in threads:
        thread.start()
    start_gate.set()
    for thread in threads:
        thread.join(timeout=12)
    stuck = [thread.name for thread in threads if thread.is_alive()]
    if stuck:
        with lock:
            failures.append(
                {
                    "worker": "cohort",
                    "phase": "join",
                    "error_type": "Timeout",
                    "sqlstate": None,
                    "message": f"worker threads did not finish: {','.join(stuck)}",
                }
            )

    with lock:
        completed = sorted(record["worker"] for record in results)
        failure_copy = list(failures)
        peak = peak_sessions

    attempt = {
        "plan_id": plan["plan_id"],
        "database": plan["database"],
        "role": plan["role"],
        "socket": plan["socket"],
        "required_sessions": required,
        "peak_sessions": peak,
        "completed_workers": completed,
        "failure_count": len(failure_copy),
        "failures": failure_copy,
        "started_ns": started_ns,
        "finished_ns": time.time_ns(),
    }
    write_json(output / "attempt.json", attempt)

    if len(completed) != required or peak != required or failure_copy:
        print(
            f"POOL_WIDTH_INCOMPLETE required={required} peak={peak} "
            f"completed={len(completed)} failures={len(failure_copy)}",
            file=sys.stderr,
        )
        return 12

    manifest = {
        "plan_id": plan["plan_id"],
        "status": "complete",
        "database": plan["database"],
        "role": plan["role"],
        "socket": plan["socket"],
        "required_sessions": required,
        "peak_sessions": peak,
        "workers": completed,
        "backend_pids": sorted(record["backend_pid"] for record in results),
        "started_ns": started_ns,
        "finished_ns": time.time_ns(),
    }
    write_json(output / "manifest.json", manifest)
    print(f"POOL_WIDTH_OK required={required} peak={peak} workers={','.join(completed)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
