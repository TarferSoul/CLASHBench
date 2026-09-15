#!/usr/bin/env python3
"""Synchronous eval-card HTTP service with a fixed FIFO worker pool."""

import argparse
import http.server
import json
import os
import pathlib
import queue
import signal
import socketserver
import threading
import time
import uuid

from eval_report_common import build_report, canonical


class ServiceState:
    def __init__(self, args):
        self.args = args
        self.generation = uuid.uuid4().hex
        self.started_at = time.time()
        self.lock = threading.RLock()
        self.next_ticket = 1
        self.waiting = {}
        self.active = {}
        self.completed = {}
        self.worker_completions = {}
        self.queue = queue.Queue(maxsize=args.queue_capacity)
        self.shutdown = threading.Event()
        self.state_root = pathlib.Path(args.state_root)
        self.output_root = pathlib.Path(args.output_root)
        self.source_root = pathlib.Path(args.source_root)
        self.events_path = self.state_root / "events.jsonl"
        self.metrics_path = self.state_root / "metrics.json"
        self.manifest_path = self.output_root / "report_manifest.jsonl"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self.output_root.mkdir(parents=True, exist_ok=True)
        pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
        self.emit("service_started", pid=os.getpid(), worker_count=args.workers)

    def metrics_unlocked(self):
        return {
            "schema": "eval-report-pool-metrics-v1",
            "service_pid": os.getpid(),
            "started_at": self.started_at,
            "queue_generation": self.generation,
            "worker_count": self.args.workers,
            "queue_capacity": self.args.queue_capacity,
            "active_worker_count": len(self.active),
            "queued_request_count": len(self.waiting),
            "next_ticket": self.next_ticket,
            "completed_count": len(self.completed),
            "active": list(self.active.values()),
            "queued": list(self.waiting.values()),
            "completed_tickets": sorted(self.completed),
            "worker_completions": self.worker_completions,
        }

    def write_metrics_unlocked(self):
        tmp = self.metrics_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self.metrics_unlocked(), sort_keys=True, indent=2) + "\n")
        tmp.replace(self.metrics_path)

    def emit(self, event, **fields):
        with self.lock:
            self.emit_unlocked(event, **fields)

    def emit_unlocked(self, event, **fields):
        row = {
            "event": event,
            "time": time.time(),
            "monotonic": time.monotonic(),
            "queue_generation": self.generation,
            **fields,
        }
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
        self.write_metrics_unlocked()

    def enqueue(self, body):
        with self.lock:
            ticket = self.next_ticket
            self.next_ticket += 1
            request_id = str(body.get("request_id") or f"report_request_{ticket}")
            report_id = str(body.get("report_id") or "")
            client_label = str(body.get("client_label") or "report-client")
            job = {
                "ticket": ticket,
                "request_id": request_id,
                "report_id": report_id,
                "client_label": client_label,
                "body": body,
                "enqueued_at": time.time(),
                "enqueued_monotonic": time.monotonic(),
                "done": threading.Event(),
                "result": None,
                "error": None,
            }
            waiting_record = {
                "ticket": ticket,
                "request_id": request_id,
                "report_id": report_id,
                "candidate_run_id": body.get("candidate_run_id"),
                "baseline_run_id": body.get("baseline_run_id"),
                "client_label": client_label,
                "enqueued_at": job["enqueued_at"],
            }
            self.waiting[ticket] = waiting_record
            try:
                self.queue.put_nowait(job)
            except queue.Full:
                self.waiting.pop(ticket, None)
                self.emit_unlocked("rejected_queue_full", **waiting_record)
                return None, "queue_full"
            self.emit_unlocked("enqueued", **waiting_record)
            return job, None

    def dispatch(self, worker_id, job):
        with self.lock:
            self.waiting.pop(job["ticket"], None)
            record = {
                "ticket": job["ticket"],
                "request_id": job["request_id"],
                "report_id": job["report_id"],
                "candidate_run_id": job["body"].get("candidate_run_id"),
                "baseline_run_id": job["body"].get("baseline_run_id"),
                "client_label": job["client_label"],
                "worker_id": worker_id,
                "dispatched_at": time.time(),
            }
            self.active[job["ticket"]] = record
            self.emit_unlocked("dispatched", **record)

    def complete(self, worker_id, job, report, service_ms):
        record_path = self.output_root / f"{job['ticket']:05d}_{job['request_id']}.json"
        html_path = self.output_root / f"{job['ticket']:05d}_{job['request_id']}.html"
        html = report["html_report"]
        response = {
            **report,
            "queue_ticket": job["ticket"],
            "service_ms": round(service_ms, 3),
        }
        record = {
            "ticket": job["ticket"],
            "request_id": job["request_id"],
            "report_id": job["report_id"],
            "candidate_run_id": job["body"].get("candidate_run_id"),
            "baseline_run_id": job["body"].get("baseline_run_id"),
            "client_label": job["client_label"],
            "worker_id": worker_id,
            "record_path": str(record_path),
            "html_path": str(html_path),
            "artifact_digest": report["artifact_digest"],
            "response_digest": report["response_digest"],
            "service_ms": round(service_ms, 3),
            "completed_at": time.time(),
        }
        record_path.write_text(json.dumps(response, sort_keys=True, indent=2) + "\n")
        html_path.write_text(html)
        with self.manifest_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        with self.lock:
            self.active.pop(job["ticket"], None)
            self.completed[job["ticket"]] = record
            key = str(worker_id)
            self.worker_completions[key] = self.worker_completions.get(key, 0) + 1
            self.emit_unlocked("completed", **record)
        return response

    def fail(self, worker_id, job, error):
        with self.lock:
            self.active.pop(job["ticket"], None)
            self.emit_unlocked(
                "failed",
                ticket=job["ticket"],
                request_id=job["request_id"],
                report_id=job["report_id"],
                client_label=job["client_label"],
                worker_id=worker_id,
                error=str(error),
            )


class ReportHandler(http.server.BaseHTTPRequestHandler):
    server_version = "eval-reportd/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    @property
    def state(self):
        return self.server.state

    def send_json(self, status, value):
        payload = json.dumps(value, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path not in {"/healthz", "/metrics"}:
            self.send_json(404, {"error": "not_found"})
            return
        with self.state.lock:
            metrics = self.state.metrics_unlocked()
        if self.path == "/metrics":
            self.send_json(200, metrics)
        else:
            self.send_json(
                200,
                {
                    "ok": True,
                    "service": "eval-reportd",
                    "pid": os.getpid(),
                    "queue_generation": metrics["queue_generation"],
                    "worker_count": metrics["worker_count"],
                    "active_worker_count": metrics["active_worker_count"],
                    "queued_request_count": metrics["queued_request_count"],
                    "completed_count": metrics["completed_count"],
                },
            )

    def do_POST(self):
        if self.path != "/v1/reports/eval-card":
            self.send_json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length") or "0")
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            for field in (
                "request_id",
                "report_id",
                "candidate_run_id",
                "baseline_run_id",
                "scorer_version",
            ):
                if not body.get(field):
                    self.send_json(400, {"error": "missing_field", "field": field})
                    return
        except Exception as exc:
            self.send_json(400, {"error": "bad_request", "detail": str(exc)})
            return
        job, error = self.state.enqueue(body)
        if error:
            self.send_json(503, {"error": error})
            return
        if not job["done"].wait(self.state.args.max_wait_seconds):
            self.send_json(504, {"error": "worker_timeout", "queue_ticket": job["ticket"]})
            return
        if job["error"]:
            self.send_json(500, {"error": "render_failed", "detail": job["error"]})
            return
        try:
            self.send_json(200, job["result"])
        except (BrokenPipeError, ConnectionResetError):
            return


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def worker_loop(state, worker_id):
    while not state.shutdown.is_set():
        try:
            job = state.queue.get(timeout=0.1)
        except queue.Empty:
            continue
        state.dispatch(worker_id, job)
        started = time.monotonic()
        try:
            client_label = job["client_label"]
            if client_label == "nightly-report-client":
                floor = state.args.a_service_seconds
            else:
                floor = state.args.b_service_seconds
            report = build_report(state.source_root, job["body"], floor)
            response = state.complete(worker_id, job, report, (time.monotonic() - started) * 1000.0)
            job["result"] = response
        except Exception as exc:
            job["error"] = f"{type(exc).__name__}: {exc}"
            state.fail(worker_id, job, exc)
        finally:
            job["done"].set()
            state.queue.task_done()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--queue-capacity", type=int, required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--a-service-seconds", type=float, default=0.85)
    parser.add_argument("--b-service-seconds", type=float, default=0.25)
    parser.add_argument("--max-wait-seconds", type=float, default=90.0)
    args = parser.parse_args()

    state = ServiceState(args)
    workers = []
    for worker_id in range(1, args.workers + 1):
        thread = threading.Thread(target=worker_loop, args=(state, worker_id), daemon=True)
        thread.start()
        workers.append(thread)

    server = ThreadedHTTPServer((args.host, args.port), ReportHandler)
    server.state = state

    def handle_stop(signum, frame):
        state.shutdown.set()
        server.shutdown()

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    state.emit("http_listening", pid=os.getpid(), endpoint=f"{args.host}:{args.port}")
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        state.shutdown.set()
        state.emit("service_stopped", pid=os.getpid())


if __name__ == "__main__":
    main()
