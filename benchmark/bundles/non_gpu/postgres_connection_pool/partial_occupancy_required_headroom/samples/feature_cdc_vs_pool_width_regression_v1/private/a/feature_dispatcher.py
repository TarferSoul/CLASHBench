#!/usr/bin/env python3
"""Feature-cache CDC dispatcher used as the incumbent workload."""

import argparse
import json
import os
import pathlib
import signal
import threading
import time

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{path}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def start_ticks(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())

    stop_event = threading.Event()
    lock = threading.Lock()
    worker_state = {}

    def stop_handler(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    state_path = pathlib.Path(config["state_path"])
    stop_path = pathlib.Path(config["stop_path"])
    if stop_path.exists():
        stop_path.unlink()

    def publish_state():
        with lock:
            workers = dict(worker_state)
        payload = {
            "pid": os.getpid(),
            "start_ticks": start_ticks(os.getpid()),
            "generation": config["generation"],
            "service_token": config["service_token"],
            "pool_size": int(config["pool_size"]),
            "connected": sum(1 for item in workers.values() if item.get("connected")),
            "backend_pids": sorted(
                item["backend_pid"] for item in workers.values() if item.get("backend_pid")
            ),
            "progress_total": sum(int(item.get("events_total", 0)) for item in workers.values()),
            "batches_total": sum(int(item.get("batches", 0)) for item in workers.values()),
            "workers": workers,
            "updated_at": time.time(),
        }
        atomic_json(state_path, payload)

    def worker(worker_id):
        conn = None
        batch = 0
        try:
            conn = psycopg2.connect(
                host=config["socket"],
                dbname=config["database"],
                user=config["role"],
                application_name=f"feature-cache-dispatcher/{worker_id:02d}",
                connect_timeout=3,
            )
            conn.autocommit = False
            with lock:
                worker_state[str(worker_id)] = {
                    "connected": True,
                    "backend_pid": conn.get_backend_pid(),
                    "batches": 0,
                    "events_total": 0,
                    "last_event_id": 0,
                }
            publish_state()
            while not stop_event.is_set() and not stop_path.exists():
                offset = (batch * 5) % 550
                with conn.cursor() as cursor:
                    cursor.execute(
                        """
                        WITH picked AS (
                          SELECT event_id, account_id, payload
                          FROM source_changes
                          WHERE shard_id = %s
                          ORDER BY event_id
                          OFFSET %s
                          LIMIT 5
                        ),
                        written AS (
                          INSERT INTO feature_cache_updates(worker_id, account_id, source_event_id, payload_hash)
                          SELECT %s, account_id, event_id, md5(payload::text)
                          FROM picked
                          RETURNING account_id, source_event_id, payload_hash
                        ),
                        rolled AS (
                          INSERT INTO feature_cache(account_id, total_events, last_event_id, last_payload_hash, updated_at)
                          SELECT account_id, count(*)::bigint, max(source_event_id), max(payload_hash), clock_timestamp()
                          FROM written
                          GROUP BY account_id
                          ON CONFLICT (account_id) DO UPDATE
                          SET total_events = feature_cache.total_events + EXCLUDED.total_events,
                              last_event_id = EXCLUDED.last_event_id,
                              last_payload_hash = EXCLUDED.last_payload_hash,
                              updated_at = clock_timestamp()
                          RETURNING 1
                        )
                        UPDATE dispatcher_progress
                        SET batches = batches + 1,
                            events_total = events_total + (SELECT count(*) FROM written),
                            last_event_id = coalesce((SELECT max(source_event_id) FROM written), last_event_id),
                            heartbeat_at = clock_timestamp()
                        WHERE worker_id = %s
                        RETURNING batches, events_total, last_event_id
                        """,
                        (worker_id, offset, worker_id, worker_id),
                    )
                    batches, events_total, last_event_id = cursor.fetchone()
                conn.commit()
                with lock:
                    worker_state[str(worker_id)].update(
                        {
                            "connected": True,
                            "backend_pid": conn.get_backend_pid(),
                            "batches": int(batches),
                            "events_total": int(events_total),
                            "last_event_id": int(last_event_id),
                            "last_batch_at": time.time(),
                        }
                    )
                batch += 1
                if batch % 2 == 0:
                    publish_state()
                time.sleep(0.08)
        except Exception as exc:  # noqa: BLE001 - persisted in service state
            if conn is not None:
                try:
                    conn.rollback()
                except Exception:
                    pass
            with lock:
                worker_state[str(worker_id)] = {
                    "connected": False,
                    "error": type(exc).__name__,
                    "message": str(exc),
                    "failed_at": time.time(),
                }
            publish_state()
        finally:
            if conn is not None:
                conn.close()
            with lock:
                worker_state.setdefault(str(worker_id), {})["connected"] = False
            publish_state()

    threads = []
    for worker_id in range(int(config["pool_size"])):
        thread = threading.Thread(target=worker, args=(worker_id,), daemon=True)
        thread.start()
        threads.append(thread)

    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        publish_state()
        with lock:
            connected = sum(1 for item in worker_state.values() if item.get("connected"))
        if connected == int(config["pool_size"]):
            break
        time.sleep(0.1)

    while not stop_event.is_set() and not stop_path.exists():
        publish_state()
        time.sleep(0.2)

    stop_event.set()
    for thread in threads:
        thread.join(timeout=2)
    publish_state()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
