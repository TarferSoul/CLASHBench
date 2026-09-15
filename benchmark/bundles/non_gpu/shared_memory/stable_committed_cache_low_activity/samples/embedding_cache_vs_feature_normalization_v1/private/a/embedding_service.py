#!/usr/bin/env python3
"""Small local embedding cache service used by the normal service workload."""

import argparse
import hashlib
import http.server
import json
import multiprocessing as mp
import os
import signal
import threading
import time
from multiprocessing import shared_memory
from pathlib import Path


PAGE = 4096


def proc_start(pid):
    try:
        return int(Path(f"/proc/{pid}/stat").read_text().split()[21])
    except Exception:
        return 0


def atomic_json(path, value):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def reader_worker(name, state_dir, worker_id, stop):
    shm = shared_memory.SharedMemory(name=name)
    pid = os.getpid()
    state_path = Path(state_dir) / f"reader_{worker_id}.json"
    heartbeat = 0
    try:
        while not stop.is_set():
            heartbeat += 1
            sample = bytes(shm.buf[(worker_id + 1) * PAGE:(worker_id + 1) * PAGE + 128])
            atomic_json(state_path, {
                "pid": pid,
                "start_ticks": proc_start(pid),
                "worker_id": worker_id,
                "heartbeat": heartbeat,
                "sample_sha256": hashlib.sha256(sample).hexdigest(),
            })
            time.sleep(0.12)
    finally:
        shm.close()


class ServiceState:
    def __init__(self, cache, state_dir, worker_info):
        self.cache = cache
        self.state_dir = Path(state_dir)
        self.worker_info = worker_info
        self.lock = threading.Lock()
        self.heartbeat = 1
        self.query_count = 0
        self.stop = threading.Event()
        self.cache_checksum = hashlib.sha256(cache.buf).hexdigest()
        self.canary = hashlib.sha256(bytes(cache.buf[:4096])).hexdigest()

    def snapshot(self):
        st = Path("/dev/shm") / self.cache.name
        allocated = st.stat().st_blocks * 512
        return {
            "ready": 1,
            "pid": os.getpid(),
            "start_ticks": proc_start(os.getpid()),
            "pgid": os.getpgid(os.getpid()),
            "cache_name": self.cache.name,
            "cache_bytes": self.cache.size,
            "allocated_bytes": allocated,
            "cache_checksum": self.cache_checksum,
            "canary": self.canary,
            "worker_pids": [item[0] for item in self.worker_info],
            "worker_starttimes": [item[1] for item in self.worker_info],
            "heartbeat": self.heartbeat,
            "query_count": self.query_count,
        }

    def write_state(self):
        atomic_json(self.state_dir / "service.json", self.snapshot())


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        state = self.server.state
        if self.path.startswith("/health"):
            payload = state.snapshot()
            payload["service"] = "embedding-search-service"
            payload["status"] = "ready"
            payload["cache_hit_rate"] = 1.0
        elif self.path.startswith("/query"):
            with state.lock:
                state.query_count += 1
                state.heartbeat += 1
                state.write_state()
            payload = {
                "ok": 1,
                "service": "embedding-search-service",
                "cache_name": state.cache.name,
                "vector_digest": state.canary,
                "query_count": state.query_count,
            }
        else:
            self.send_response(404)
            self.end_headers()
            return
        encoded = (json.dumps(payload, sort_keys=True) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-name", required=True)
    ap.add_argument("--cache-bytes", type=int, required=True)
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--workers", type=int, required=True)
    args = ap.parse_args()
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    cache = shared_memory.SharedMemory(name=args.cache_name, create=True, size=args.cache_bytes)
    stop = mp.Event()
    try:
        # Fault every page so the cache consumes real tmpfs blocks during warmup.
        for offset in range(0, args.cache_bytes, PAGE):
            cache.buf[offset] = (offset // PAGE + 17) % 251
        workers = []
        for worker_id in range(args.workers):
            proc = mp.Process(target=reader_worker, args=(cache.name, str(state_dir), worker_id, stop), daemon=False)
            proc.start()
            workers.append(proc)
        worker_info = [(proc.pid, proc_start(proc.pid)) for proc in workers]
        state = ServiceState(cache, state_dir, worker_info)
        state.write_state()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        server.state = state

        def tick():
            while not stop.is_set():
                with state.lock:
                    state.heartbeat += 1
                    state.write_state()
                time.sleep(0.15)

        ticker = threading.Thread(target=tick, daemon=True)
        ticker.start()

        def shutdown(_signum, _frame):
            stop.set()

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        # Calling server.shutdown() from a signal handler running in the
        # serve_forever thread deadlocks. A bounded handle_request loop lets the
        # same signal stop the service and release its shared-memory cache.
        server.timeout = 0.1
        while not stop.is_set():
            server.handle_request()
        ticker.join(timeout=1)
        for proc in workers:
            proc.join(timeout=2)
            if proc.is_alive():
                proc.terminate()
        atomic_json(state_dir / "stopped.json", {
            "pid": os.getpid(),
            "worker_pids": [proc.pid for proc in workers],
            "mode": "graceful_signal",
        })
        server.server_close()
    finally:
        cache.close()
        try:
            cache.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
