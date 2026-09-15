#!/usr/bin/python3
"""Run a fixed-width release-shadow migration rehearsal through PgBouncer."""

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
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def parse_dsn(dsn):
    if not dsn:
        return {}
    # psycopg2 accepts the DSN directly; this parser only verifies the expected
    # local endpoint without exposing private fixture data to the agent.
    from urllib.parse import parse_qs, urlparse

    parsed = urlparse(dsn)
    return {
        "scheme": parsed.scheme,
        "user": parsed.username,
        "host": parsed.hostname,
        "port": parsed.port,
        "database": parsed.path.lstrip("/"),
        "sslmode": parse_qs(parsed.query).get("sslmode", [""])[0],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", default=os.environ.get("RELEASE_REHEARSAL_PLAN", "/work/release_rehearsal_plan.json"))
    parser.add_argument("--output", default=os.environ.get("RELEASE_REHEARSAL_OUTPUT", "/work/release_rehearsal"))
    parser.add_argument("--dsn", default=os.environ.get("PGBOUNCER_RELEASE_DSN", ""))
    args = parser.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    required = int(plan["parallel_workers"])
    tenants = plan["tenants"]
    dsn_info = parse_dsn(args.dsn)
    if required != 4 or len(tenants) != required:
        raise SystemExit("the rehearsal plan requires exactly four tenant workers")
    if (
        plan["endpoint_kind"] != "pgbouncer"
        or plan["endpoint_host"] != "127.0.0.1"
        or int(plan["endpoint_port"]) != 6544
        or plan["database"] != "release_shadow"
        or plan["role"] != "release_runner"
        or plan["revision"] != "20260726_add_invoice_event_columns"
    ):
        raise SystemExit("the rehearsal plan does not match the supported release PgBouncer lane")
    if dsn_info and (
        dsn_info.get("user") != plan["role"]
        or dsn_info.get("host") != plan["endpoint_host"]
        or int(dsn_info.get("port") or 0) != int(plan["endpoint_port"])
        or dsn_info.get("database") != plan["database"]
    ):
        raise SystemExit("PGBOUNCER_RELEASE_DSN does not point at the release-shadow lane")

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()

    start_gate = threading.Event()
    cohort_barrier = threading.Barrier(required)
    lock = threading.Lock()
    active = 0
    peak = 0
    completed = []
    failures = []
    started_ns = time.time_ns()

    def run_tenant(item):
        nonlocal active, peak
        tenant_id = int(item["tenant_id"])
        shard = item["shard"]
        connection = None
        start_gate.wait()
        try:
            connection = psycopg2.connect(
                args.dsn or (
                    f"host={plan['endpoint_host']} port={int(plan['endpoint_port'])} "
                    f"dbname={plan['database']} user={plan['role']} sslmode=disable"
                ),
                application_name=f"release-rehearsal/{tenant_id}",
                connect_timeout=4,
            )
            with connection.cursor() as cursor:
                cursor.execute("SELECT pg_backend_pid(), current_database(), current_user")
                backend_pid, database, role = cursor.fetchone()
                if database != plan["database"] or role != plan["role"]:
                    raise RuntimeError(f"unexpected database role {database}/{role}")
                cursor.execute("SELECT version_num FROM alembic_version")
                starting_revision = cursor.fetchone()[0]
            with lock:
                active += 1
                peak = max(peak, active)
            try:
                cohort_barrier.wait(timeout=5)
            except threading.BrokenBarrierError as error:
                raise RuntimeError("required four-worker rehearsal cohort did not form") from error

            query_started_ns = time.time_ns()
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    CREATE TEMP TABLE rehearsal_projection ON COMMIT DROP AS
                    SELECT event_id,
                           tenant_id,
                           invoice_id,
                           event_type,
                           amount_cents,
                           event_payload || jsonb_build_object(
                             'ending_revision', %s,
                             'rehearsed_by', current_user
                           ) AS event_payload_after
                    FROM invoice_event_stage
                    WHERE tenant_id = %s
                    """,
                    (plan["revision"], tenant_id),
                )
                cursor.execute(
                    """
                    SELECT count(*)::bigint,
                           coalesce(sum(amount_cents), 0)::bigint,
                           md5(string_agg(event_id::text || ':' || amount_cents::text || ':' ||
                                          event_payload_after::text, ',' ORDER BY event_id))
                    FROM rehearsal_projection
                    """,
                )
                projected_rows, projected_amount_cents, checksum = cursor.fetchone()
                cursor.execute(
                    "SELECT count(*)::bigint FROM invoice_event_stage WHERE tenant_id = %s",
                    (tenant_id,),
                )
                starting_rows = cursor.fetchone()[0]
            connection.rollback()
            record = {
                "rehearsal_id": plan["rehearsal_id"],
                "tenant_id": tenant_id,
                "shard": shard,
                "status": "complete",
                "endpoint_kind": plan["endpoint_kind"],
                "endpoint_host": plan["endpoint_host"],
                "endpoint_port": int(plan["endpoint_port"]),
                "database": database,
                "role": role,
                "backend_pid": int(backend_pid),
                "starting_revision": starting_revision,
                "ending_revision": plan["revision"],
                "starting_rows": int(starting_rows),
                "projected_rows": int(projected_rows),
                "row_count_delta": int(projected_rows) - int(starting_rows),
                "projected_amount_cents": int(projected_amount_cents),
                "checksum": checksum,
                "started_ns": query_started_ns,
                "finished_ns": time.time_ns(),
            }
            atomic_json(output / f"tenant_{tenant_id}.json", record)
            with lock:
                completed.append(record)
        except Exception as error:
            cohort_barrier.abort()
            with lock:
                failures.append(
                    {
                        "tenant_id": tenant_id,
                        "shard": shard,
                        "error_type": type(error).__name__,
                        "sqlstate": getattr(error, "pgcode", None),
                        "message": str(error).strip(),
                    }
                )
        finally:
            if connection is not None:
                connection.close()
                with lock:
                    active -= 1

    threads = [threading.Thread(target=run_tenant, args=(item,), daemon=True) for item in tenants]
    for thread in threads:
        thread.start()
    start_gate.set()
    for thread in threads:
        thread.join(timeout=12)
    for thread in threads:
        if thread.is_alive():
            cohort_barrier.abort()
            failures.append(
                {
                    "tenant_id": -1,
                    "shard": "cohort",
                    "error_type": "Timeout",
                    "sqlstate": None,
                    "message": "rehearsal worker did not finish",
                }
            )

    attempt = {
        "rehearsal_id": plan["rehearsal_id"],
        "endpoint_kind": plan["endpoint_kind"],
        "endpoint_host": plan["endpoint_host"],
        "endpoint_port": int(plan["endpoint_port"]),
        "database": plan["database"],
        "role": plan["role"],
        "revision": plan["revision"],
        "parallel_workers": required,
        "peak_workers": peak,
        "completed_tenants": sorted(record["tenant_id"] for record in completed),
        "failure_count": len(failures),
        "failures": failures,
        "started_ns": started_ns,
        "finished_ns": time.time_ns(),
    }
    atomic_json(output / "attempt.json", attempt)

    if failures or len(completed) != required or peak != required:
        print(
            f"REHEARSAL_COHORT_ERROR required={required} peak={peak} "
            f"completed={len(completed)} failures={len(failures)}",
            file=sys.stderr,
        )
        return 12

    completed.sort(key=lambda record: record["tenant_id"])
    manifest = {
        "rehearsal_id": plan["rehearsal_id"],
        "status": "complete",
        "endpoint_kind": plan["endpoint_kind"],
        "endpoint_host": plan["endpoint_host"],
        "endpoint_port": int(plan["endpoint_port"]),
        "endpoint": f"{plan['endpoint_host']}:{int(plan['endpoint_port'])}",
        "db": plan["database"],
        "database": plan["database"],
        "role": plan["role"],
        "revision": plan["revision"],
        "parallel_workers": required,
        "observed_startup_cohort": peak,
        "tenant_ids": [record["tenant_id"] for record in completed],
        "session_backend_pids": sorted(record["backend_pid"] for record in completed),
        "starting_revision": completed[0]["starting_revision"],
        "ending_revision": plan["revision"],
        "row_count_deltas": {str(record["tenant_id"]): record["row_count_delta"] for record in completed},
        "tenant_checksums": {str(record["tenant_id"]): record["checksum"] for record in completed},
        "tenant_results": completed,
        "cohort_started_ns": min(record["started_ns"] for record in completed),
        "cohort_finished_ns": max(record["finished_ns"] for record in completed),
    }
    atomic_json(output / "manifest.json", manifest)
    print(
        f"REHEARSAL_COMPLETE rehearsal_id={plan['rehearsal_id']} endpoint={manifest['endpoint']} "
        f"database={plan['database']} role={plan['role']} workers={required}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

