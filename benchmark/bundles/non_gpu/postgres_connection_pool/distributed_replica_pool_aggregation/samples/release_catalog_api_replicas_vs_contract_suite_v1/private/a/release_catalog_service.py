#!/usr/bin/python3
"""Local release-catalog API supervisor and database replica workers."""

import hashlib
import http.server
import json
import multiprocessing
import os
import pathlib
import signal
import socketserver
import threading
import time

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(
        f"{path}.{os.getpid()}.{threading.get_ident()}.{time.time_ns()}.tmp"
    )
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)
    os.chmod(path, 0o644)


class ReplicaState:
    def __init__(self, config, replica_name, backend_pids):
        self.lock = threading.Lock()
        self.path = pathlib.Path(config["state_dir"]) / f"{replica_name}.json"
        self.value = {
            "phase": "running",
            "replica_name": replica_name,
            "pid": os.getpid(),
            "token": config["service_token"],
            "generation": config["generation"],
            "pool_size": int(config["pool_per_replica"]),
            "backend_pids": backend_pids,
            "processed_events": 0,
            "last_event_id": None,
            "last_catalog_rows": 0,
            "started_at_epoch": time.time(),
            "updated_at_epoch": time.time(),
        }
        self.write_locked()

    def write_locked(self):
        self.value["updated_at_epoch"] = time.time()
        atomic_json(self.path, self.value)

    def record_progress(self, event_id, catalog_rows):
        with self.lock:
            self.value["processed_events"] += 1
            self.value["last_event_id"] = event_id
            self.value["last_catalog_rows"] = catalog_rows
            if self.value["processed_events"] % 2 == 0:
                self.write_locked()

    def stop(self, phase):
        with self.lock:
            self.value["phase"] = phase
            self.write_locked()


def connect(config, replica_name):
    conn = psycopg2.connect(
        host=config["socket"],
        dbname=config["database"],
        user=config["role"],
        application_name=replica_name,
        connect_timeout=3,
    )
    conn.autocommit = False
    return conn


def worker_loop(conn, config, replica_name, state, stop_event):
    try:
        while not stop_event.is_set() and not pathlib.Path(config["stop_path"]).exists():
            event = None
            catalog_rows = 0
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT e.event_id, e.package_id, e.version, e.source_sha,
                           e.artifact_path, e.download_count, p.package_name,
                           p.ecosystem, p.owner_team
                    FROM staged_release_events e
                    JOIN package_metadata p ON p.package_id = e.package_id
                    WHERE e.status = 'pending'
                    ORDER BY e.event_id
                    FOR UPDATE OF e SKIP LOCKED
                    LIMIT 1
                    """
                )
                event = cursor.fetchone()
                if event is not None:
                    (
                        event_id,
                        package_id,
                        version,
                        source_sha,
                        artifact_path,
                        download_count,
                        package_name,
                        ecosystem,
                        owner_team,
                    ) = event
                    digest = hashlib.sha256(
                        f"{event_id}:{source_sha}:{artifact_path}:{package_name}:{version}".encode()
                    ).hexdigest()
                    cursor.execute(
                        """
                        INSERT INTO release_catalog(
                          event_id, package_id, package_name, version, ecosystem,
                          owner_team, artifact_digest, download_count, replica_name
                        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (event_id) DO UPDATE
                        SET artifact_digest = EXCLUDED.artifact_digest,
                            replica_name = EXCLUDED.replica_name,
                            processed_at = clock_timestamp()
                        """,
                        (
                            event_id,
                            package_id,
                            package_name,
                            version,
                            ecosystem,
                            owner_team,
                            digest,
                            download_count,
                            replica_name,
                        ),
                    )
                    cursor.execute(
                        "UPDATE staged_release_events SET status = 'processed' WHERE event_id = %s",
                        (event_id,),
                    )
                    cursor.execute(
                        """
                        UPDATE replica_progress
                        SET processed_events = processed_events + 1,
                            last_event_id = %s,
                            updated_at = clock_timestamp()
                        WHERE replica_name = %s
                        """,
                        (event_id, replica_name),
                    )
                    cursor.execute("SELECT count(*)::bigint FROM release_catalog")
                    catalog_rows = cursor.fetchone()[0]
                    cursor.execute(
                        """
                        UPDATE release_readiness
                        SET service_generation = %s,
                            replica_count = %s,
                            catalog_rows = %s,
                            updated_at = clock_timestamp()
                        WHERE id = 1
                        """,
                        (config["generation"], int(config["replica_count"]), catalog_rows),
                    )
            conn.commit()
            if event is not None:
                state.record_progress(event[0], catalog_rows)
                stop_event.wait(0.03)
            else:
                stop_event.wait(0.08)
    except Exception:
        conn.rollback()
        stop_event.set()
        raise
    finally:
        conn.close()


def replica_main(config, replica_index):
    replica_name = f"release_catalog_replica_{replica_index}"
    stop_event = multiprocessing.Event()

    def request_stop(_signum=None, _frame=None):
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    connections = [connect(config, replica_name) for _ in range(int(config["pool_per_replica"]))]
    backend_pids = []
    for conn in connections:
        with conn.cursor() as cursor:
            cursor.execute("SELECT pg_backend_pid()")
            backend_pids.append(cursor.fetchone()[0])
        conn.commit()

    state = ReplicaState(config, replica_name, backend_pids)
    threads = [
        threading.Thread(
            target=worker_loop,
            args=(conn, config, replica_name, state, stop_event),
            daemon=True,
        )
        for conn in connections
    ]
    for thread in threads:
        thread.start()
    while not stop_event.is_set() and any(thread.is_alive() for thread in threads):
        state.write_locked()
        stop_event.wait(0.5)
    stop_event.set()
    for thread in threads:
        thread.join(timeout=2)
    state.stop("stopped")


def read_replica_states(config):
    states = []
    for path in sorted(pathlib.Path(config["state_dir"]).glob("release_catalog_replica_*.json")):
        try:
            states.append(json.loads(path.read_text()))
        except Exception:
            continue
    return states


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


class HealthHandler(http.server.BaseHTTPRequestHandler):
    config = None

    def do_GET(self):
        if self.path not in {"/ready", "/metrics"}:
            self.send_response(404)
            self.end_headers()
            return
        states = read_replica_states(self.config)
        ready = (
            len(states) == int(self.config["replica_count"])
            and all(item.get("phase") == "running" for item in states)
            and all(item.get("pool_size") == int(self.config["pool_per_replica"]) for item in states)
        )
        payload = {
            "ready": ready,
            "generation": self.config["generation"],
            "replicas": len(states),
            "processed_events": sum(int(item.get("processed_events", 0)) for item in states),
            "states": states if self.path == "/ready" else [],
        }
        body = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        self.send_response(200 if ready else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        return


def main():
    config_path = pathlib.Path(os.environ["SERVICE_CONFIG"])
    config = json.loads(config_path.read_text())
    pathlib.Path(config["stop_path"]).unlink(missing_ok=True)
    pathlib.Path(config["state_dir"]).mkdir(parents=True, exist_ok=True)
    for old in pathlib.Path(config["state_dir"]).glob("release_catalog_replica_*.json"):
        old.unlink()

    stopping = multiprocessing.Event()

    def request_stop(_signum=None, _frame=None):
        stopping.set()
        pathlib.Path(config["stop_path"]).touch()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    processes = []
    for replica_index in range(int(config["replica_count"])):
        proc = multiprocessing.Process(target=replica_main, args=(config, replica_index))
        proc.start()
        processes.append(proc)

    HealthHandler.config = config
    with ReusableTCPServer((config["api_host"], int(config["api_port"])), HealthHandler) as httpd:
        httpd.timeout = 0.5
        while not stopping.is_set() and all(proc.is_alive() for proc in processes):
            httpd.handle_request()

    request_stop()
    for proc in processes:
        proc.join(timeout=3)
    for proc in processes:
        if proc.is_alive():
            proc.terminate()
    for proc in processes:
        proc.join(timeout=2)


if __name__ == "__main__":
    main()
