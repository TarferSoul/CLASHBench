#!/usr/bin/python3
"""Run one productive replica of the sharded document indexer."""

import hashlib
import json
import os
import pathlib
import re
import signal
import sys
import threading
import time

import psycopg2


class ReplicaState:
    def __init__(self, config, backend_pids):
        self.path = pathlib.Path(config["state_path"])
        self.lock = threading.Lock()
        self.value = {
            "phase": "starting",
            "replica": config["replica"],
            "shard": config["shard"],
            "instance_token": config["instance_token"],
            "generation": config["generation"],
            "pid": os.getpid(),
            "pool_size": config["pool_size"],
            "backend_pids": backend_pids,
            "healthy_workers": 0,
            "total_commits": 0,
            "documents_indexed": 0,
            "last_document_id": None,
            "started_at_epoch": time.time(),
            "updated_at_epoch": time.time(),
        }
        self.write_locked()

    def write_locked(self):
        self.value["updated_at_epoch"] = time.time()
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.value, indent=2, sort_keys=True) + "\n")
        os.replace(tmp, self.path)
        os.chmod(self.path, 0o644)

    def set_running(self, workers):
        with self.lock:
            self.value["phase"] = "running"
            self.value["healthy_workers"] = workers
            self.write_locked()

    def commit(self, document_id, indexed):
        with self.lock:
            self.value["total_commits"] += 1
            self.value["documents_indexed"] += int(indexed)
            if document_id is not None:
                self.value["last_document_id"] = document_id
            if self.value["total_commits"] % 4 == 0:
                self.write_locked()

    def worker_stopped(self):
        with self.lock:
            self.value["healthy_workers"] -= 1
            self.write_locked()

    def stop(self, phase):
        with self.lock:
            self.value["phase"] = phase
            self.write_locked()


def connect(config, worker):
    conn = psycopg2.connect(
        host=config["socket"],
        dbname=config["database"],
        user=config["role"],
        application_name=f"document-index/{config['replica']}/{worker}",
        connect_timeout=3,
    )
    conn.autocommit = False
    return conn


def index_loop(conn, worker, config, state, stopping):
    try:
        while not stopping.is_set():
            document = None
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT s.document_id, s.title, s.body
                    FROM source_documents s
                    LEFT JOIN search_index i ON i.document_id = s.document_id
                    WHERE s.shard = %s AND i.document_id IS NULL
                    ORDER BY s.document_id
                    FOR UPDATE OF s SKIP LOCKED
                    LIMIT 1
                    """,
                    (config["shard"],),
                )
                document = cursor.fetchone()
                if document is not None:
                    document_id, title, body = document
                    normalized = " ".join(re.findall(r"[a-z0-9]+", f"{title} {body}".lower()))
                    digest = hashlib.sha256(normalized.encode()).hexdigest()
                    token_count = len(normalized.split())
                    cursor.execute(
                        """
                        INSERT INTO search_index(
                          document_id, shard, token_count, content_digest, replica, worker
                        ) VALUES (%s, %s, %s, %s, %s, %s)
                        ON CONFLICT (document_id) DO NOTHING
                        """,
                        (
                            document_id,
                            config["shard"],
                            token_count,
                            digest,
                            config["replica"],
                            worker,
                        ),
                    )
                    cursor.execute(
                        """
                        UPDATE replica_progress
                        SET commits = commits + 1,
                            documents_indexed = documents_indexed + 1,
                            last_document_id = %s,
                            updated_at = clock_timestamp()
                        WHERE replica = %s AND worker = %s
                        """,
                        (document_id, config["replica"], worker),
                    )
            conn.commit()
            state.commit(document[0] if document else None, document is not None)
            stopping.wait(0.04 if document is not None else 0.1)
    except Exception as exc:
        conn.rollback()
        print(f"{config['replica']}/{worker} failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        stopping.set()
    finally:
        conn.close()
        state.worker_stopped()


def main():
    config_path = pathlib.Path(
        os.environ.get("REPLICA_CONFIG", "/etc/document-indexer/alpha.json")
    )
    config = json.loads(config_path.read_text())
    stop_path = pathlib.Path(config["stop_path"])
    stop_path.unlink(missing_ok=True)
    stopping = threading.Event()

    def request_stop(_signum=None, _frame=None):
        stopping.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    connections = []
    names = [f"worker-{index}" for index in range(config["pool_size"])]
    try:
        for name in names:
            connections.append((name, connect(config, name)))
        backend_pids = {}
        for name, conn in connections:
            with conn.cursor() as cursor:
                cursor.execute("SELECT pg_backend_pid()")
                backend_pids[name] = cursor.fetchone()[0]
            conn.commit()

        state = ReplicaState(config, backend_pids)
        threads = []
        for name, conn in connections:
            thread = threading.Thread(
                target=index_loop,
                args=(conn, name, config, state, stopping),
                name=name,
            )
            thread.start()
            threads.append(thread)
        state.set_running(len(threads))

        unexpected_stop = False
        while not stopping.wait(0.1):
            if stop_path.exists():
                stopping.set()
            elif not all(thread.is_alive() for thread in threads):
                unexpected_stop = True
                stopping.set()
        for thread in threads:
            thread.join(timeout=5)
        clean_join = all(not thread.is_alive() for thread in threads)
        healthy_exit = clean_join and not unexpected_stop
        state.stop("stopped" if healthy_exit else "failed")
        return 0 if healthy_exit else 1
    except Exception as exc:
        print(f"replica failure: {type(exc).__name__}: {exc}", file=sys.stderr)
        for _name, conn in connections:
            try:
                conn.close()
            except Exception:
                pass
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
