#!/usr/bin/env python3
import hashlib
import json
import os
import queue
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ["A_HOST"]
PORT = int(os.environ["A_PORT"])
SERVICE = os.environ["A_SERVICE"]
IDENTITY = os.environ["A_IDENTITY"]
WORKERS = int(os.environ["A_WORKERS"])
QUEUE_CAPACITY = int(os.environ["A_QUEUE_CAPACITY"])
WORK_SECONDS = float(os.environ["A_REQUEST_SECONDS"])
METRICS_FILE = os.environ["A_METRICS_FILE"]
EVENTS_FILE = os.environ["A_EVENTS_FILE"]
GENERATION_FILE = os.environ["A_GENERATION_FILE"]
IDENTITY_FILE = os.environ["A_IDENTITY_FILE"]

work_queue = queue.Queue(maxsize=QUEUE_CAPACITY)
stop_event = threading.Event()
metrics_lock = threading.Lock()
metrics_file_lock = threading.Lock()
events_file_lock = threading.Lock()
metrics = {
    "service": SERVICE,
    "identity": IDENTITY,
    "generation": int(os.environ.get("A_GENERATION", "1")),
    "workers": WORKERS,
    "queue_capacity": QUEUE_CAPACITY,
    "total_requests": 0,
    "completed": 0,
    "successful": 0,
    "a_completed": 0,
    "b_completed": 0,
    "http_5xx": 0,
    "active": 0,
    "max_active": 0,
    "started_at": time.time(),
}


class Work:
    def __init__(self, body):
        self.body = body
        self.done = threading.Event()
        self.status = 500
        self.response = {"valid": False, "error": "not_processed"}


def write_metrics():
    with metrics_file_lock:
        with metrics_lock:
            snapshot = dict(metrics)
        snapshot["queue_depth"] = work_queue.qsize()
        snapshot["timestamp"] = time.time()
        tmp = METRICS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, METRICS_FILE)


def write_event(payload):
    record = {"ts": time.time(), **payload}
    with events_file_lock:
        with open(EVENTS_FILE, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
            handle.flush()


def worker():
    while not stop_event.is_set():
        try:
            item = work_queue.get(timeout=0.1)
        except queue.Empty:
            continue
        with metrics_lock:
            metrics["active"] += 1
            metrics["max_active"] = max(metrics["max_active"], metrics["active"])
        write_metrics()
        try:
            time.sleep(WORK_SECONDS)
            claim_id = str(item.body.get("claim_id", ""))
            canonical = json.dumps(item.body, sort_keys=True, separators=(",", ":")).encode()
            checksum = hashlib.sha256(canonical).hexdigest()
            item.status = 200
            item.response = {
                "valid": True,
                "service": SERVICE,
                "identity": IDENTITY,
                "claim_id": claim_id,
                "validation_checksum": checksum,
            }
            with metrics_lock:
                metrics["successful"] += 1
                if item.body.get("source") == "nightly-reconciliation":
                    metrics["a_completed"] += 1
                    source = "nightly-reconciliation"
                else:
                    metrics["b_completed"] += 1
                    source = "claims-audit"
            write_event({
                "event": "completed",
                "source": source,
                "claim_id": claim_id,
                "checksum": checksum,
            })
        except Exception as exc:
            item.status = 500
            item.response = {"valid": False, "error": type(exc).__name__}
            with metrics_lock:
                metrics["http_5xx"] += 1
        finally:
            with metrics_lock:
                metrics["completed"] += 1
                metrics["active"] -= 1
            item.done.set()
            work_queue.task_done()
            write_metrics()


class Handler(BaseHTTPRequestHandler):
    server_version = "BillingRules/2.7"

    def log_message(self, *_args):
        return

    def send_json(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/healthz":
            with metrics_lock:
                payload = {"ready": True, "service": SERVICE, "identity": IDENTITY, "generation": metrics["generation"]}
            self.send_json(200, payload)
            return
        if self.path == "/metrics":
            with metrics_lock:
                payload = dict(metrics)
            payload["queue_depth"] = work_queue.qsize()
            payload["timestamp"] = time.time()
            self.send_json(200, payload)
            return
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/reconcile":
            self.send_json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(body, dict) or not body.get("claim_id"):
                raise ValueError("claim_id_required")
        except Exception:
            with metrics_lock:
                metrics["http_5xx"] += 1
            self.send_json(400, {"valid": False, "error": "bad_request"})
            return
        item = Work(body)
        with metrics_lock:
            metrics["total_requests"] += 1
        try:
            work_queue.put(item, timeout=0.4)
        except queue.Full:
            with metrics_lock:
                metrics["http_5xx"] += 1
            self.send_json(503, {"valid": False, "error": "queue_full"})
            write_metrics()
            return
        if not item.done.wait(timeout=8.0):
            self.send_json(504, {"valid": False, "error": "service_deadline"})
            return
        self.send_json(item.status, item.response)


def handle_signal(_signum, _frame):
    stop_event.set()


def main():
    os.makedirs(os.path.dirname(METRICS_FILE), exist_ok=True)
    with open(IDENTITY_FILE, "w", encoding="utf-8") as handle:
        handle.write(IDENTITY + "\n")
    with open(GENERATION_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(metrics["generation"]) + "\n")
    write_metrics()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    workers = [threading.Thread(target=worker, name="rules-worker", daemon=True) for _ in range(WORKERS)]
    for thread in workers:
        thread.start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    server.timeout = 0.2
    while not stop_event.is_set():
        server.handle_request()
    server.server_close()
    for thread in workers:
        thread.join(timeout=2)
    write_metrics()


if __name__ == "__main__":
    main()
