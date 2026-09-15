#!/usr/bin/python3
"""Stream compliance evidence partitions through stable snapshot cursors."""

import hashlib
import json
import os
import pathlib
import signal
import threading
import time

import psycopg2


config = json.loads(pathlib.Path(os.environ["SERVICE_CONFIG"]).read_text())
max_fetches = int(os.environ.get("A_MAX_FETCHES", "0"))
stop_event = threading.Event()
lock = threading.Lock()
workers = {}
errors = []


def atomic_state(phase):
    value = {
        "pid": os.getpid(),
        "phase": phase,
        "service_token": config["service_token"],
        "generation": config["generation"],
        "pool_size": config["pool_size"],
        "healthy_workers": sum(1 for item in workers.values() if item.get("connected") and not item.get("done")),
        "total_fetches": sum(item.get("fetches", 0) for item in workers.values()),
        "rows_streamed": sum(item.get("rows", 0) for item in workers.values()),
        "output_bytes": sum(item.get("bytes", 0) for item in workers.values()),
        "workers": workers,
        "errors": list(errors),
        "updated_at_epoch": time.time(),
    }
    path = pathlib.Path(config["state_path"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def request_stop(_signum=None, _frame=None):
    stop_event.set()


def run_partition(partition):
    name = f"partition-{partition:02d}"
    app = f"{config['application_prefix']}/{name}"
    cursor_name = f"{config['cursor_prefix']}_{partition:02d}"
    digest = hashlib.sha256()
    conn = None
    try:
        conn = psycopg2.connect(
            host=config["socket"],
            port=config["port"],
            dbname=config["database"],
            user=config["role"],
            application_name=app,
            connect_timeout=3,
        )
        conn.set_session(readonly=True, isolation_level="REPEATABLE READ", autocommit=False)
        with conn.cursor() as meta:
            meta.execute("SELECT pg_backend_pid(), txid_current_snapshot()::text")
            backend_pid, snapshot = meta.fetchone()
        cursor = conn.cursor(name=cursor_name)
        cursor.itersize = config["chunk_size"]
        cursor.execute(
            """
            SELECT e.event_id, e.account_id, e.team, e.action, e.privileged,
                   e.occurred_at, pass_no
            FROM audit_events e
            CROSS JOIN generate_series(1, 30) AS pass_no
            WHERE mod(e.account_id, %s) = %s
            ORDER BY pass_no, e.account_id, e.event_id
            """,
            (config["pool_size"], partition),
        )
        with lock:
            workers[name] = {
                "application_name": app,
                "backend_pid": backend_pid,
                "snapshot": snapshot,
                "cursor": cursor_name,
                "transaction_read_only": True,
                "connected": True,
                "done": False,
                "fetches": 0,
                "rows": 0,
                "bytes": 0,
                "digest": digest.hexdigest(),
            }
        while not stop_event.is_set() and not pathlib.Path(config["stop_path"]).exists():
            rows = cursor.fetchmany(config["chunk_size"])
            if not rows:
                break
            payload = "\n".join("|".join(map(str, row)) for row in rows).encode()
            digest.update(payload)
            with lock:
                item = workers[name]
                item["fetches"] += 1
                item["rows"] += len(rows)
                item["bytes"] += len(payload)
                item["digest"] = digest.hexdigest()
                reached_limit = max_fetches and item["fetches"] >= max_fetches
            if reached_limit:
                break
            time.sleep(config["fetch_delay_seconds"])
        cursor.close()
        conn.commit()
        with lock:
            workers[name]["done"] = True
            workers[name]["connected"] = False
    except Exception as exc:
        with lock:
            errors.append(f"{name}:{type(exc).__name__}:{exc}")
            workers.setdefault(name, {})["done"] = True
        stop_event.set()
    finally:
        if conn is not None:
            conn.close()


def main():
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    threads = [threading.Thread(target=run_partition, args=(i,), daemon=True) for i in range(config["pool_size"])]
    for thread in threads:
        thread.start()
    while any(thread.is_alive() for thread in threads):
        with lock:
            atomic_state("running" if not errors else "failed")
        time.sleep(0.1)
    for thread in threads:
        thread.join()
    with lock:
        atomic_state("failed" if errors else "complete")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
