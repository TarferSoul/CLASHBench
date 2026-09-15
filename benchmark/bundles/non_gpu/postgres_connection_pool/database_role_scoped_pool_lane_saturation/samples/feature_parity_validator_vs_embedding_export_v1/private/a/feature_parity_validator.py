#!/usr/bin/python3
"""Continuously validate feature-store parity snapshots through PgBouncer."""

import argparse
import hashlib
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


def digest_rows(rows):
    digest = hashlib.sha256()
    bytes_streamed = 0
    for row in rows:
        encoded = json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8")
        digest.update(encoded)
        digest.update(b"\n")
        bytes_streamed += len(encoded) + 1
    return digest.hexdigest(), bytes_streamed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    pool_size = int(config["pool_size"])
    hold_seconds = float(config["hold_seconds"])
    partitions = ["fs-a", "fs-b", "fs-c", "fs-d", "fs-e"]

    state_lock = threading.Lock()
    state = {
        "pid": os.getpid(),
        "phase": "starting",
        "service_token": config["service_token"],
        "generation": config["generation"],
        "pool_generation": config["pool_generation"],
        "model_version": config["model_version"],
        "pool_size": pool_size,
        "healthy_workers": 0,
        "active_partition_ids": [],
        "worker_started_epoch": {},
        "last_backend_pids": {},
        "worker_checkpoints": {},
        "worker_partitions": {},
        "last_hashes": {},
        "rows_hashed": 0,
        "bytes_streamed": 0,
        "completed_checkpoint_count": 0,
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
        name = f"feature-parity-validator-{index}"
        partition = partitions[index % len(partitions)]
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
                state["worker_checkpoints"][name] = 0
                state["worker_partitions"][name] = partition
                state["active_partition_ids"] = sorted(set(state["worker_partitions"].values()))
                state["healthy_workers"] = len(state["worker_started_epoch"])
                if state["healthy_workers"] == pool_size:
                    state["phase"] = "running"

            update(register)
            while not stop_event.is_set():
                backend_pid = None
                sha256 = None
                bytes_streamed = 0
                row_count = 0
                with connection.cursor() as cursor:
                    cursor.execute("SELECT pg_backend_pid(), current_database(), current_user")
                    backend_pid, database, role = cursor.fetchone()
                    if database != config["database"] or role != config["role"]:
                        raise RuntimeError(f"unexpected lane identity {database}/{role}")
                    cursor.execute(
                        """
                        SELECT feature_name, embedding_dim, visibility_tag
                        FROM model_version_metadata
                        WHERE model_version = %s
                        """,
                        (config["model_version"],),
                    )
                    metadata = cursor.fetchone()
                    if metadata is None or metadata[0] != "embedding_feature_v3":
                        raise RuntimeError("feature metadata missing")
                    cursor.execute(
                        """
                        SELECT tenant_id,
                               shard_id,
                               model_version,
                               entity_id,
                               embedding_vector::text,
                               embedding_norm::text,
                               feature_payload::text
                        FROM embedding_feature_v3
                        WHERE shard_id = %s
                          AND model_version = %s
                        ORDER BY tenant_id, entity_id
                        """,
                        (partition, config["model_version"]),
                    )
                    rows = [
                        {
                            "tenant_id": int(row[0]),
                            "shard_id": row[1],
                            "model_version": row[2],
                            "entity_id": int(row[3]),
                            "embedding_vector": row[4],
                            "embedding_norm": row[5],
                            "feature_payload": row[6],
                        }
                        for row in cursor.fetchall()
                    ]
                    row_count = len(rows)
                    sha256, bytes_streamed = digest_rows(rows)
                    cursor.execute(
                        """
                        INSERT INTO feature_snapshot_audit(
                            worker_name, partition_id, model_version, completed_checkpoints,
                            rows_hashed, bytes_streamed, last_sha256
                        ) VALUES (%s, %s, %s, 1, %s, %s, %s)
                        ON CONFLICT (worker_name) DO UPDATE
                        SET completed_checkpoints = feature_snapshot_audit.completed_checkpoints + 1,
                            partition_id = EXCLUDED.partition_id,
                            model_version = EXCLUDED.model_version,
                            rows_hashed = feature_snapshot_audit.rows_hashed + EXCLUDED.rows_hashed,
                            bytes_streamed = feature_snapshot_audit.bytes_streamed + EXCLUDED.bytes_streamed,
                            last_sha256 = EXCLUDED.last_sha256,
                            updated_at = clock_timestamp()
                        """,
                        (name, partition, config["model_version"], row_count, bytes_streamed, sha256),
                    )
                    cursor.execute("SELECT pg_sleep(%s)", (hold_seconds,))
                connection.commit()

                def record_progress():
                    state["last_backend_pids"][name] = int(backend_pid)
                    state["worker_checkpoints"][name] += 1
                    state["completed_checkpoint_count"] += 1
                    state["rows_hashed"] += row_count
                    state["bytes_streamed"] += bytes_streamed
                    state["last_hashes"][name] = sha256

                update(record_progress)
                partition = partitions[(partitions.index(partition) + pool_size) % len(partitions)]
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

    threads = [
        threading.Thread(target=worker, args=(index,), name=f"feature-parity-{index}")
        for index in range(pool_size)
    ]
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
