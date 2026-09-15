#!/usr/bin/env python3
import hashlib
import json
import os
import queue
import signal
import socket
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer


HOST = os.environ.get("A_HOST", "127.0.0.1")
PORT = int(os.environ.get("A_PORT", "25783"))
SERVICE_NAME = os.environ.get("A_SERVICE_NAME", "search-enrichment")
STATE_DIR = os.environ.get("A_STATE_DIR", "/run/http_pool_search_enrichment")
METRICS_FILE = os.environ.get("A_METRICS_FILE", os.path.join(STATE_DIR, "metrics.json"))
EVENTS_FILE = os.environ.get("A_EVENTS_FILE", os.path.join(STATE_DIR, "events.jsonl"))
PID_FILE = os.environ.get("A_SERVICE_PID_FILE", os.path.join(STATE_DIR, "service.pid"))
WORKERS = int(os.environ.get("WORKERS", "2"))
QUEUE_CAPACITY = int(os.environ.get("QUEUE_CAPACITY", "64"))
SERVICE_DELAY = int(os.environ.get("SERVICE_DELAY_MS", "160")) / 1000.0


class WorkerPoolHTTPServer(HTTPServer):
    request_queue_size = 128
    allow_reuse_address = True

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.identity = str(uuid.uuid4())
        self.generation = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        self.started_at = time.time()
        self.work_queue = queue.Queue(maxsize=QUEUE_CAPACITY)
        self.stop_event = threading.Event()
        self.metrics_lock = threading.Lock()
        self.event_lock = threading.Lock()
        self.metrics = {
            "service": SERVICE_NAME,
            "identity": self.identity,
            "generation": self.generation,
            "pid": os.getpid(),
            "workers": WORKERS,
            "queue_capacity": QUEUE_CAPACITY,
            "active": 0,
            "max_active": 0,
            "accepted": 0,
            "completed": 0,
            "server_errors": 0,
            "client_disconnects": 0,
            "by_source": {},
            "completed_by_source": {},
            "queue_depth": 0,
            "max_queue_depth": 0,
            "last_update": time.time(),
        }
        self.pool_threads = []
        for idx in range(WORKERS):
            thread = threading.Thread(target=self.worker_loop, name=f"http-worker-{idx}", daemon=True)
            thread.start()
            self.pool_threads.append(thread)
        self.publish_metrics()

    def process_request(self, request, client_address):
        enqueued_at = time.monotonic()
        self.work_queue.put((request, client_address, enqueued_at))
        with self.metrics_lock:
            self.metrics["accepted"] += 1
            depth = self.work_queue.qsize()
            self.metrics["queue_depth"] = depth
            self.metrics["max_queue_depth"] = max(self.metrics["max_queue_depth"], depth)
            self.metrics["last_update"] = time.time()
        self.publish_metrics()

    def worker_loop(self):
        while not self.stop_event.is_set():
            try:
                request, client_address, enqueued_at = self.work_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            with self.metrics_lock:
                self.metrics["active"] += 1
                self.metrics["max_active"] = max(self.metrics["max_active"], self.metrics["active"])
                self.metrics["queue_depth"] = self.work_queue.qsize()
                self.metrics["last_update"] = time.time()
            self.publish_metrics()
            try:
                self.finish_request(request, client_address)
                self.shutdown_request(request)
            except Exception:
                with self.metrics_lock:
                    self.metrics["server_errors"] += 1
                    self.metrics["last_update"] = time.time()
                self.handle_error(request, client_address)
                self.shutdown_request(request)
            finally:
                with self.metrics_lock:
                    self.metrics["active"] -= 1
                    self.metrics["queue_depth"] = self.work_queue.qsize()
                    self.metrics["last_update"] = time.time()
                self.publish_metrics()
                self.work_queue.task_done()

    def note_source(self, source):
        with self.metrics_lock:
            by_source = self.metrics["by_source"]
            by_source[source] = by_source.get(source, 0) + 1
            self.metrics["last_update"] = time.time()

    def note_completed(self, source):
        with self.metrics_lock:
            completed = self.metrics["completed_by_source"]
            completed[source] = completed.get(source, 0) + 1
            self.metrics["completed"] += 1
            self.metrics["last_update"] = time.time()

    def note_disconnect(self):
        with self.metrics_lock:
            self.metrics["client_disconnects"] += 1
            self.metrics["last_update"] = time.time()

    def event(self, payload):
        payload = {"ts": time.time(), **payload}
        line = json.dumps(payload, sort_keys=True)
        with self.event_lock:
            with open(EVENTS_FILE, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")

    def snapshot(self):
        with self.metrics_lock:
            data = dict(self.metrics)
            data["by_source"] = dict(self.metrics["by_source"])
            data["completed_by_source"] = dict(self.metrics["completed_by_source"])
            data["queue_depth"] = self.work_queue.qsize()
            data["active"] = self.metrics["active"]
        return data

    def publish_metrics(self):
        os.makedirs(os.path.dirname(METRICS_FILE), exist_ok=True)
        data = self.snapshot()
        tmp = f"{METRICS_FILE}.{os.getpid()}.{threading.get_ident()}.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, METRICS_FILE)

    def server_close(self):
        self.stop_event.set()
        return super().server_close()


class Handler(BaseHTTPRequestHandler):
    server_version = "SearchEnrichmentHTTP/1.0"

    def log_message(self, fmt, *args):
        return

    def send_json(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            self.server.note_disconnect()

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {
                "ready": True,
                "service": SERVICE_NAME,
                "identity": self.server.identity,
                "generation": self.server.generation,
            })
            return
        if self.path == "/metrics":
            self.send_json(200, self.server.snapshot())
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/enrich":
            self.send_json(404, {"error": "not_found"})
            return
        source = self.headers.get("X-Client-Workload", "unknown")
        self.server.note_source(source)
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        started = time.time()
        try:
            document = json.loads(raw.decode("utf-8"))
            text = "|".join(str(document.get(key, "")) for key in ("doc_id", "collection", "title", "body"))
            digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
            for _ in range(120):
                digest = hashlib.sha256((digest + text).encode("utf-8")).hexdigest()
            remaining = SERVICE_DELAY - (time.time() - started)
            if remaining > 0:
                time.sleep(remaining)
            payload = {
                "ok": True,
                "doc_id": document.get("doc_id"),
                "collection": document.get("collection"),
                "enrichment_checksum": digest[:24],
                "terms": len(str(document.get("body", "")).split()),
                "service": SERVICE_NAME,
                "elapsed_ms": round((time.time() - started) * 1000, 3),
            }
            self.server.note_completed(source)
            self.server.event({
                "event": "completed",
                "source": source,
                "doc_id": document.get("doc_id"),
                "checksum": payload["enrichment_checksum"],
            })
            self.send_json(200, payload)
        except Exception as exc:
            with self.server.metrics_lock:
                self.server.metrics["server_errors"] += 1
            self.send_json(500, {"ok": False, "error": type(exc).__name__})


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(PID_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()) + "\n")
    server = WorkerPoolHTTPServer((HOST, PORT), Handler)

    def term(_signum, _frame):
        server.server_close()
        sys.exit(0)

    signal.signal(signal.SIGTERM, term)
    signal.signal(signal.SIGINT, term)
    print(json.dumps({"service": SERVICE_NAME, "pid": os.getpid(), "identity": server.identity, "port": PORT}), flush=True)
    server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    socket.setdefaulttimeout(5)
    main()
