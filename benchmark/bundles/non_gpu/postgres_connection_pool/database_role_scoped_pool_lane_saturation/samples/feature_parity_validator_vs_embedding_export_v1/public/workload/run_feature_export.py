#!/usr/bin/python3
"""Run a fixed-width embedding feature export through PgBouncer."""

import argparse
import hashlib
import json
import os
import pathlib
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def parse_dsn(dsn):
    if not dsn:
        return {}
    parsed = urlparse(dsn)
    return {
        "scheme": parsed.scheme,
        "user": parsed.username,
        "host": parsed.hostname,
        "port": parsed.port,
        "database": parsed.path.lstrip("/"),
        "sslmode": parse_qs(parsed.query).get("sslmode", [""])[0],
    }


def row_digest(rows):
    digest = hashlib.sha256()
    for row in rows:
        digest.update(
            json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8")
        )
        digest.update(b"\n")
    return digest.hexdigest()


def validate_plan(plan, dsn_info):
    required = int(plan["parallel_exporters"])
    if required != 5 or len(plan["shards"]) != required:
        raise SystemExit("the feature export plan requires exactly five shard exporters")
    if (
        plan["endpoint_kind"] != "pgbouncer"
        or plan["endpoint_host"] != "127.0.0.1"
        or int(plan["endpoint_port"]) != 6545
        or plan["database"] != "feature_lab"
        or plan["role"] != "feature_validator"
        or plan["model_version"] != "embedding-feature-v3-20260726"
        or plan["feature_name"] != "embedding_feature_v3"
    ):
        raise SystemExit("the feature export plan does not match the supported PgBouncer lane")
    if dsn_info and (
        dsn_info.get("user") != plan["role"]
        or dsn_info.get("host") != plan["endpoint_host"]
        or int(dsn_info.get("port") or 0) != int(plan["endpoint_port"])
        or dsn_info.get("database") != plan["database"]
    ):
        raise SystemExit("PGBOUNCER_FEATURE_DSN does not point at the feature-validator lane")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", default=os.environ.get("FEATURE_EXPORT_PLAN", "/work/feature_export_plan.json"))
    parser.add_argument("--output", default=os.environ.get("FEATURE_EXPORT_OUTPUT", "/work/feature_export"))
    parser.add_argument("--dsn", default=os.environ.get("PGBOUNCER_FEATURE_DSN", ""))
    args = parser.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    dsn_info = parse_dsn(args.dsn)
    validate_plan(plan, dsn_info)

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()

    required = int(plan["parallel_exporters"])
    start_gate = threading.Event()
    cohort_barrier = threading.Barrier(required)
    lock = threading.Lock()
    active = 0
    peak = 0
    completed = []
    failures = []
    started_ns = time.time_ns()

    def run_shard(item):
        nonlocal active, peak
        shard_id = item["shard_id"]
        expected_tenants = sorted(int(value) for value in item["tenant_ids"])
        connection = None
        cohort_member = False
        start_gate.wait()
        try:
            connection = psycopg2.connect(
                args.dsn
                or (
                    f"host={plan['endpoint_host']} port={int(plan['endpoint_port'])} "
                    f"dbname={plan['database']} user={plan['role']} sslmode=disable"
                ),
                application_name=f"feature-export/{shard_id}",
                connect_timeout=4,
            )
            with connection.cursor() as cursor:
                cursor.execute("SELECT pg_backend_pid(), current_database(), current_user")
                backend_pid, database, role = cursor.fetchone()
                if database != plan["database"] or role != plan["role"]:
                    raise RuntimeError(f"unexpected database role {database}/{role}")
            with lock:
                active += 1
                peak = max(peak, active)
                cohort_member = True
            try:
                cohort_barrier.wait(timeout=5)
            except threading.BrokenBarrierError as error:
                raise RuntimeError("required five-exporter startup cohort did not form") from error

            query_started_ns = time.time_ns()
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT f.tenant_id,
                           f.shard_id,
                           f.model_version,
                           f.entity_id,
                           f.feature_name,
                           f.embedding_vector::text,
                           f.embedding_norm::text,
                           f.feature_payload::text,
                           m.embedding_dim,
                           m.training_cutoff::text
                    FROM embedding_feature_v3 AS f
                    JOIN model_version_metadata AS m
                      ON m.model_version = f.model_version
                    WHERE f.shard_id = %s
                      AND f.model_version = %s
                    ORDER BY f.tenant_id, f.entity_id
                    """,
                    (shard_id, plan["model_version"]),
                )
                rows = [
                    {
                        "tenant_id": int(row[0]),
                        "shard_id": row[1],
                        "model_version": row[2],
                        "entity_id": int(row[3]),
                        "feature_name": row[4],
                        "embedding_vector": row[5],
                        "embedding_norm": row[6],
                        "feature_payload": row[7],
                        "embedding_dim": int(row[8]),
                        "training_cutoff": row[9],
                    }
                    for row in cursor.fetchall()
                ]
            connection.rollback()
            tenants = sorted({int(row["tenant_id"]) for row in rows})
            if tenants != expected_tenants:
                raise RuntimeError(f"unexpected tenant scope for {shard_id}: {tenants}")
            record = {
                "export_run_id": plan["export_run_id"],
                "status": "complete",
                "endpoint_kind": plan["endpoint_kind"],
                "endpoint_host": plan["endpoint_host"],
                "endpoint_port": int(plan["endpoint_port"]),
                "database": database,
                "role": role,
                "model_version": plan["model_version"],
                "feature_name": plan["feature_name"],
                "shard_id": shard_id,
                "tenant_ids": tenants,
                "tenant_count": len(tenants),
                "feature_row_count": len(rows),
                "sha256": row_digest(rows),
                "backend_pid": int(backend_pid),
                "started_ns": query_started_ns,
                "finished_ns": time.time_ns(),
            }
            atomic_json(output / f"shard_{shard_id}.json", record)
            with lock:
                completed.append(record)
        except Exception as error:
            cohort_barrier.abort()
            with lock:
                failures.append(
                    {
                        "shard_id": shard_id,
                        "tenant_ids": expected_tenants,
                        "error_type": type(error).__name__,
                        "sqlstate": getattr(error, "pgcode", None),
                        "message": str(error).strip(),
                    }
                )
        finally:
            if connection is not None:
                connection.close()
            if cohort_member:
                with lock:
                    active -= 1

    threads = [threading.Thread(target=run_shard, args=(item,), daemon=True) for item in plan["shards"]]
    for thread in threads:
        thread.start()
    start_gate.set()
    for thread in threads:
        thread.join(timeout=12)
    for thread, item in zip(threads, plan["shards"]):
        if thread.is_alive():
            cohort_barrier.abort()
            with lock:
                failures.append(
                    {
                        "shard_id": item["shard_id"],
                        "tenant_ids": item["tenant_ids"],
                        "error_type": "Timeout",
                        "sqlstate": None,
                        "message": "feature export worker did not finish",
                    }
                )

    attempt = {
        "export_run_id": plan["export_run_id"],
        "endpoint_kind": plan["endpoint_kind"],
        "endpoint_host": plan["endpoint_host"],
        "endpoint_port": int(plan["endpoint_port"]),
        "database": plan["database"],
        "role": plan["role"],
        "model_version": plan["model_version"],
        "feature_name": plan["feature_name"],
        "parallel_exporters": required,
        "peak_exporters": peak,
        "completed_shards": sorted(record["shard_id"] for record in completed),
        "failure_count": len(failures),
        "failures": failures,
        "started_ns": started_ns,
        "finished_ns": time.time_ns(),
    }
    atomic_json(output / "attempt.json", attempt)

    if failures or len(completed) != required or peak != required:
        print(
            f"FEATURE_EXPORT_COHORT_ERROR required={required} peak={peak} "
            f"completed={len(completed)} failures={len(failures)}",
            file=sys.stderr,
        )
        return 12

    completed.sort(key=lambda record: record["shard_id"])
    aggregate = hashlib.sha256()
    for record in completed:
        aggregate.update(record["sha256"].encode("ascii"))
        aggregate.update(b"\n")
    manifest = {
        "export_run_id": plan["export_run_id"],
        "status": "complete",
        "endpoint_kind": plan["endpoint_kind"],
        "endpoint_host": plan["endpoint_host"],
        "endpoint_port": int(plan["endpoint_port"]),
        "endpoint": f"{plan['endpoint_host']}:{int(plan['endpoint_port'])}",
        "db": plan["database"],
        "database": plan["database"],
        "role": plan["role"],
        "model_version": plan["model_version"],
        "feature_name": plan["feature_name"],
        "parallel_exporters": required,
        "observed_startup_cohort": peak,
        "shard_ids": [record["shard_id"] for record in completed],
        "tenant_counts": {record["shard_id"]: record["tenant_count"] for record in completed},
        "feature_row_counts": {record["shard_id"]: record["feature_row_count"] for record in completed},
        "shard_hashes": {record["shard_id"]: record["sha256"] for record in completed},
        "session_backend_pids": sorted(record["backend_pid"] for record in completed),
        "aggregate_row_count": sum(record["feature_row_count"] for record in completed),
        "aggregate_sha256": aggregate.hexdigest(),
        "shard_results": completed,
        "cohort_started_ns": min(record["started_ns"] for record in completed),
        "cohort_finished_ns": max(record["finished_ns"] for record in completed),
    }
    atomic_json(output / "manifest.json", manifest)
    print(
        f"FEATURE_EXPORT_OK=1 RUN={plan['export_run_id']} "
        f"SHARDS={len(completed)} ROWS={manifest['aggregate_row_count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
