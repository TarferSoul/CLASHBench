#!/usr/bin/python3
"""Build a fixed-width privileged-access review snapshot."""

import argparse
import json
import os
import pathlib
import sys
import threading
import time

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def capacity_error(exc):
    message = str(exc).strip()
    sqlstate = getattr(exc, "pgcode", None)
    if sqlstate is None and ("remaining connection slots are reserved" in message or "too many clients already" in message):
        sqlstate = "53300"
    return sqlstate, message


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    plan = json.loads(pathlib.Path(args.plan).read_text())
    required = int(plan["required_sessions"])
    teams = list(plan["teams"])
    if required != 4 or len(teams) != required:
        raise SystemExit("the access review requires exactly four concurrent sessions")

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()

    barrier = threading.Barrier(required)
    start = threading.Event()
    lock = threading.Lock()
    connected = 0
    peak = 0
    results = []
    failures = []

    def worker(team):
        nonlocal connected, peak
        conn = None
        start.wait()
        try:
            conn = psycopg2.connect(
                host=plan["socket"], port=plan["port"], dbname=plan["database"],
                user=plan["role"], application_name=f"{plan['application_prefix']}/{team}",
                connect_timeout=3,
            )
            conn.set_session(readonly=True, isolation_level="REPEATABLE READ", autocommit=False)
            with lock:
                connected += 1
                peak = max(peak, connected)
            try:
                barrier.wait(timeout=5)
            except threading.BrokenBarrierError as exc:
                raise RuntimeError("required four-snapshot cohort did not form") from exc
            with conn.cursor() as cursor:
                cursor.execute("SELECT pg_backend_pid(), txid_current_snapshot()::text, current_setting('transaction_read_only')")
                backend_pid, snapshot, read_only = cursor.fetchone()
                cursor.execute(
                    """
                    SELECT count(*)::bigint,
                           count(*) FILTER (WHERE privileged)::bigint,
                           count(DISTINCT account_id)::bigint,
                           md5(string_agg(event_id::text || ':' || action || ':' || privileged::text,
                                          ',' ORDER BY event_id))
                    FROM audit_events WHERE team = %s
                    """,
                    (team,),
                )
                row_count, privileged_count, accounts, digest = cursor.fetchone()
                time.sleep(float(plan["hold_seconds"]))
            conn.commit()
            record = {
                "report_id": plan["report_id"], "team": team, "status": "complete",
                "database": plan["database"], "role": plan["role"],
                "backend_pid": backend_pid, "snapshot": snapshot,
                "transaction_read_only": read_only == "on", "row_count": row_count,
                "privileged_count": privileged_count, "distinct_accounts": accounts,
                "digest": digest,
            }
            atomic_json(output / f"team_{team}.json", record)
            with lock:
                results.append(record)
        except Exception as exc:
            barrier.abort()
            sqlstate, message = capacity_error(exc)
            with lock:
                failures.append({"team": team, "error_type": type(exc).__name__, "sqlstate": sqlstate, "message": message})
        finally:
            if conn is not None:
                conn.close()
                with lock:
                    connected -= 1

    threads = [threading.Thread(target=worker, args=(team,), daemon=True) for team in teams]
    for thread in threads:
        thread.start()
    start.set()
    for thread in threads:
        thread.join(timeout=12)
    if any(thread.is_alive() for thread in threads):
        barrier.abort()
        failures.append({"team": "cohort", "error_type": "Timeout", "sqlstate": None, "message": "worker did not finish"})

    atomic_json(output / "attempt.json", {
        "report_id": plan["report_id"], "required_sessions": required,
        "peak_sessions": peak, "completed_teams": sorted(item["team"] for item in results),
        "failure_count": len(failures), "failures": failures,
    })
    if failures or len(results) != required or peak != required:
        print(f"COHORT_ERROR required={required} peak={peak} completed={len(results)} failures={len(failures)}", file=sys.stderr)
        return 12

    manifest = {
        "report_id": plan["report_id"], "status": "complete",
        "database": plan["database"], "role": plan["role"], "socket": plan["socket"],
        "port": plan["port"], "required_sessions": required, "peak_sessions": peak,
        "backend_pids": sorted(item["backend_pid"] for item in results),
        "teams": sorted(teams), "snapshots": sorted(item["snapshot"] for item in results),
    }
    atomic_json(output / "manifest.json", manifest)
    print(f"ACCESS_SNAPSHOT_COMPLETE report_id={plan['report_id']} sessions={required} teams={','.join(sorted(teams))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
