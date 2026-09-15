#!/usr/bin/python3
"""Build a fixed-width SearchOps shard-consistency audit."""

import argparse
import hashlib
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


def capacity_sqlstate(exc):
    value = getattr(exc, "pgcode", None)
    message = str(exc)
    if value is None and (
        "remaining connection slots are reserved" in message
        or "too many clients already" in message
    ):
        return "53300", "postgres_capacity_message"
    return value, "driver"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    required = int(plan["required_sessions"])
    shards = plan["shards"]
    if required != 4 or len(shards) != required:
        raise SystemExit("the shard audit plan must contain exactly four sessions and shards")

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()

    start_gate = threading.Event()
    cohort_barrier = threading.Barrier(required)
    lock = threading.Lock()
    connected = 0
    peak_connected = 0
    results = []
    failures = []
    audit_started = time.time_ns()

    def run_shard(shard):
        nonlocal connected, peak_connected
        name = shard["name"]
        conn = None
        start_gate.wait()
        try:
            conn = psycopg2.connect(
                host=plan["socket"],
                dbname=plan["database"],
                user=plan["role"],
                application_name=f"search-shard-audit/{name}",
                connect_timeout=3,
            )
            conn.set_session(readonly=True, isolation_level="REPEATABLE READ", autocommit=False)
            with lock:
                connected += 1
                peak_connected = max(peak_connected, connected)
            try:
                cohort_barrier.wait(timeout=4)
            except threading.BrokenBarrierError as exc:
                raise RuntimeError("required four-session cohort did not form") from exc

            started_ns = time.time_ns()
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT pg_backend_pid(), current_database(), current_user, "
                    "txid_current_snapshot()::text"
                )
                backend_pid, database, role, snapshot = cursor.fetchone()
                cursor.execute("SELECT pg_sleep(0.35)")
                cursor.execute(
                    """
                    SELECT count(*)::bigint,
                           count(i.document_id)::bigint,
                           count(*) FILTER (WHERE i.document_id IS NULL)::bigint,
                           coalesce(sum(i.token_count), 0)::bigint,
                           md5(string_agg(
                             s.document_id::text || ':' || coalesce(i.content_digest, 'pending'),
                             ',' ORDER BY s.document_id
                           ))
                    FROM source_documents s
                    LEFT JOIN search_index i ON i.document_id = s.document_id
                    WHERE s.shard = %s
                    """,
                    (int(shard["shard"]),),
                )
                source_count, indexed_count, pending_count, token_count, digest = cursor.fetchone()
            conn.commit()
            finished_ns = time.time_ns()
            record = {
                "audit_id": plan["audit_id"],
                "shard": int(shard["shard"]),
                "status": "complete",
                "database": database,
                "role": role,
                "backend_pid": backend_pid,
                "snapshot": snapshot,
                "source_count": source_count,
                "indexed_count": indexed_count,
                "pending_count": pending_count,
                "token_count": token_count,
                "digest": digest or hashlib.sha256(b"empty").hexdigest(),
                "started_ns": started_ns,
                "finished_ns": finished_ns,
            }
            atomic_json(output / f"shard_{name}.json", record)
            with lock:
                results.append(record)
        except Exception as exc:
            cohort_barrier.abort()
            sqlstate, source = capacity_sqlstate(exc)
            with lock:
                failures.append(
                    {
                        "shard": name,
                        "error_type": type(exc).__name__,
                        "sqlstate": sqlstate,
                        "sqlstate_source": source,
                        "message": str(exc).strip(),
                    }
                )
        finally:
            if conn is not None:
                conn.close()
                with lock:
                    connected -= 1

    threads = [threading.Thread(target=run_shard, args=(shard,), daemon=True) for shard in shards]
    for thread in threads:
        thread.start()
    start_gate.set()
    for thread in threads:
        thread.join(timeout=10)
    if any(thread.is_alive() for thread in threads):
        cohort_barrier.abort()
        failures.append(
            {
                "shard": "cohort",
                "error_type": "Timeout",
                "sqlstate": None,
                "message": "worker did not finish",
            }
        )

    attempt = {
        "audit_id": plan["audit_id"],
        "required_sessions": required,
        "peak_sessions": peak_connected,
        "completed_shards": sorted(record["shard"] for record in results),
        "failure_count": len(failures),
        "failures": failures,
        "started_ns": audit_started,
        "finished_ns": time.time_ns(),
    }
    atomic_json(output / "attempt.json", attempt)

    if failures or len(results) != required or peak_connected != required:
        print(
            f"COHORT_ERROR required={required} peak={peak_connected} "
            f"completed={len(results)} failures={len(failures)}",
            file=sys.stderr,
        )
        return 12

    results.sort(key=lambda item: item["shard"])
    manifest = {
        "audit_id": plan["audit_id"],
        "status": "complete",
        "database": plan["database"],
        "role": plan["role"],
        "socket": plan["socket"],
        "required_sessions": required,
        "peak_sessions": peak_connected,
        "session_backend_pids": sorted(record["backend_pid"] for record in results),
        "shards": sorted(record["shard"] for record in results),
        "cohort_started_ns": min(record["started_ns"] for record in results),
        "cohort_finished_ns": max(record["finished_ns"] for record in results),
    }
    atomic_json(output / "manifest.json", manifest)
    print(
        f"AUDIT_COMPLETE audit_id={plan['audit_id']} sessions={required} "
        f"shards={','.join(str(x) for x in manifest['shards'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
