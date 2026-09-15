#!/usr/bin/python3
"""Run release-shadow schema contract checks through a fixed PgBouncer lane."""

import argparse
import json
import os
import pathlib
import signal
import threading
import time

import psycopg2


stop_event = threading.Event()


def request_stop(_signum, _frame):
    stop_event.set()


def atomic_json(path, value):
    path = pathlib.Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    pool_size = int(config["pool_size"])
    hold_seconds = float(config["hold_seconds"])
    tenants = [4101, 4102, 4103, 4104, 4105, 4106]

    state_lock = threading.Lock()
    state = {
        "pid": os.getpid(),
        "phase": "starting",
        "service_token": config["service_token"],
        "generation": config["generation"],
        "pool_generation": config["pool_generation"],
        "target_revision": config["target_revision"],
        "pool_size": pool_size,
        "healthy_workers": 0,
        "worker_started_epoch": {},
        "last_backend_pids": {},
        "worker_commits": {},
        "worker_tenants": {},
        "last_checksums": {},
        "completed_shards": 0,
        "errors": [],
        "updated_at_epoch": time.time(),
    }

    def publish():
        state["updated_at_epoch"] = time.time()
        atomic_json(config["state_path"], state)

    def update(mutator):
        with state_lock:
            mutator()
            publish()

    with state_lock:
        pathlib.Path(config["state_path"]).parent.mkdir(parents=True, exist_ok=True)
        publish()

    def worker(index):
        name = f"release-contract-runner-{index}"
        tenant_id = tenants[index % len(tenants)]
        connection = None
        try:
            connection = psycopg2.connect(
                host=config["host"],
                port=int(config["port"]),
                dbname=config["database"],
                user=config["role"],
                application_name=name,
                connect_timeout=5,
            )

            def register():
                state["worker_started_epoch"][name] = time.time()
                state["worker_commits"][name] = 0
                state["worker_tenants"][name] = tenant_id
                state["healthy_workers"] = len(state["worker_started_epoch"])
                if state["healthy_workers"] == pool_size:
                    state["phase"] = "running"

            update(register)
            while not stop_event.is_set():
                checksum = None
                backend_pid = None
                with connection.cursor() as cursor:
                    cursor.execute("SELECT pg_backend_pid(), current_database(), current_user")
                    backend_pid, database, role = cursor.fetchone()
                    if database != config["database"] or role != config["role"]:
                        raise RuntimeError(f"unexpected lane identity {database}/{role}")
                    cursor.execute("SELECT version_num FROM alembic_version")
                    start_revision = cursor.fetchone()[0]
                    cursor.execute(
                        """
                        EXPLAIN (FORMAT JSON)
                        SELECT tenant_id, count(*) AS rows_seen, sum(amount_cents) AS cents_seen
                        FROM invoice_event_stage
                        WHERE tenant_id = %s
                        GROUP BY tenant_id
                        """,
                        (tenant_id,),
                    )
                    cursor.fetchone()
                    cursor.execute(
                        """
                        SELECT count(*)::bigint,
                               coalesce(sum(amount_cents), 0)::bigint,
                               md5(string_agg(event_id::text || ':' || amount_cents::text || ':' || event_type,
                                              ',' ORDER BY event_id))
                        FROM invoice_event_stage
                        WHERE tenant_id = %s
                        """,
                        (tenant_id,),
                    )
                    row_count, amount_cents, checksum = cursor.fetchone()
                    cursor.execute(
                        """
                        INSERT INTO release_contract_scratch(
                            worker_name, tenant_id, revision, probe_checksum
                        ) VALUES (%s, %s, %s, %s)
                        """,
                        (name, tenant_id, config["target_revision"], checksum),
                    )
                    cursor.execute(
                        """
                        DELETE FROM release_contract_scratch
                        WHERE worker_name = %s AND tenant_id = %s
                        """,
                        (name, tenant_id),
                    )
                    cursor.execute(
                        """
                        INSERT INTO release_contract_progress(
                            worker_name, worker_index, revision, completed_shards,
                            last_tenant_id, last_checksum
                        ) VALUES (%s, %s, %s, 1, %s, %s)
                        ON CONFLICT (worker_name) DO UPDATE
                        SET completed_shards = release_contract_progress.completed_shards + 1,
                            revision = EXCLUDED.revision,
                            last_tenant_id = EXCLUDED.last_tenant_id,
                            last_checksum = EXCLUDED.last_checksum,
                            updated_at = clock_timestamp()
                        """,
                        (name, index, config["target_revision"], tenant_id, checksum),
                    )
                    cursor.execute("SELECT pg_sleep(%s)", (hold_seconds,))
                connection.commit()

                def record_progress():
                    state["last_backend_pids"][name] = int(backend_pid)
                    state["worker_commits"][name] += 1
                    state["completed_shards"] += 1
                    state["last_checksums"][name] = checksum

                update(record_progress)
                tenant_id = tenants[(tenants.index(tenant_id) + pool_size) % len(tenants)]
        except Exception as error:
            if connection is not None:
                connection.rollback()

            def record_error():
                state["errors"].append(f"{name}:{type(error).__name__}:{error}")
                state["phase"] = "failed"

            update(record_error)
            stop_event.set()
        finally:
            if connection is not None:
                connection.close()

    threads = [threading.Thread(target=worker, args=(index,), name=f"release-contract-{index}") for index in range(pool_size)]
    for thread in threads:
        thread.start()
    while not stop_event.is_set() and any(thread.is_alive() for thread in threads):
        stop_event.wait(0.2)
    stop_event.set()
    for thread in threads:
        thread.join(timeout=5)
    with state_lock:
        if state["phase"] != "failed":
            state["phase"] = "stopped"
        state["healthy_workers"] = 0
        publish()
    return 1 if state["errors"] else 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    raise SystemExit(main())

