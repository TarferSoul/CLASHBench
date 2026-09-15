#!/usr/bin/env python3
"""Authoritative tenant-concurrency gateway for structured-output checks."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def atomic_json(path, value):
    target = pathlib.Path(path)
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, target)


class Ledger:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.identity = f"schema-gateway-{os.getpid()}-{time.time_ns()}"
        self.sequence = 0
        self.active_total = 0
        self.active_by_owner = {}
        self.global_peak = 0
        self.cohort_peaks = {}
        self.admitted = 0
        self.completed = 0
        self.rejected = 0
        self.write_state_locked()

    def snapshot_locked(self):
        return {
            "service": "structured-output-compatibility-gateway",
            "identity": self.identity,
            "tenant": self.args.tenant,
            "model": self.args.model,
            "capacity": self.args.capacity,
            "active_total": self.active_total,
            "active_by_owner": dict(self.active_by_owner),
            "global_peak": self.global_peak,
            "cohort_peaks": dict(self.cohort_peaks),
            "admitted": self.admitted,
            "completed": self.completed,
            "rejected": self.rejected,
            "updated_at_ns": time.time_ns(),
        }

    def write_state_locked(self):
        atomic_json(self.args.state_file, self.snapshot_locked())

    def event_locked(self, value):
        value = {**value, "gateway_identity": self.identity, "event_at_ns": time.time_ns()}
        with pathlib.Path(self.args.events_file).open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(value, sort_keys=True) + "\n")

    def admit(self, owner, cohort, case_id):
        with self.lock:
            self.sequence += 1
            request_id = f"schema-{self.sequence:06d}-{time.time_ns()}"
            if self.active_total >= self.args.capacity:
                self.rejected += 1
                self.event_locked({
                    "event": "rejected", "status": 429, "reason": "tenant_concurrency_limit",
                    "request_id": request_id, "owner": owner, "cohort_id": cohort,
                    "case_id": case_id, "active_total": self.active_total,
                    "capacity": self.args.capacity,
                })
                self.write_state_locked()
                return request_id, False, time.time_ns()
            admitted_at = time.time_ns()
            self.active_total += 1
            self.active_by_owner[owner] = self.active_by_owner.get(owner, 0) + 1
            self.admitted += 1
            self.global_peak = max(self.global_peak, self.active_total)
            self.cohort_peaks[cohort] = max(self.cohort_peaks.get(cohort, 0), self.active_by_owner[owner])
            self.event_locked({
                "event": "admitted", "status": 202, "request_id": request_id,
                "owner": owner, "cohort_id": cohort, "case_id": case_id,
                "active_total": self.active_total, "owner_active": self.active_by_owner[owner],
                "capacity": self.args.capacity, "admitted_at_ns": admitted_at,
            })
            self.write_state_locked()
            return request_id, True, admitted_at

    def finish(self, request_id, owner, cohort, case_id, admitted_at):
        completed_at = time.time_ns()
        with self.lock:
            self.active_total -= 1
            self.active_by_owner[owner] -= 1
            self.completed += 1
            self.event_locked({
                "event": "completed", "status": 200, "request_id": request_id,
                "owner": owner, "cohort_id": cohort, "case_id": case_id,
                "active_total": self.active_total, "capacity": self.args.capacity,
                "admitted_at_ns": admitted_at, "completed_at_ns": completed_at,
            })
            self.write_state_locked()
        return completed_at


class Handler(BaseHTTPRequestHandler):
    ledger = None

    def log_message(self, *_args):
        return

    def send_json(self, status, value):
        body = json.dumps(value, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Tenant-Concurrency-Limit", str(self.ledger.args.capacity))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def do_GET(self):
        if self.path not in ("/healthz", "/metrics"):
            self.send_json(404, {"error": "not_found"})
            return
        with self.ledger.lock:
            value = self.ledger.snapshot_locked()
        value["ready"] = True
        self.send_json(200, value)

    def do_POST(self):
        if self.path != "/v1/check-schema":
            self.send_json(404, {"error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            tenant = str(body["tenant"])
            model = str(body["model"])
            owner = str(body["owner"])
            cohort = str(body["cohort_id"])
            case = body["case"]
            case_id = str(case["id"])
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid_request"})
            return
        if tenant != self.ledger.args.tenant or model != self.ledger.args.model:
            self.send_json(400, {"error": "scope_mismatch", "required_tenant": self.ledger.args.tenant, "required_model": self.ledger.args.model})
            return
        request_id, admitted, admitted_at = self.ledger.admit(owner, cohort, case_id)
        if not admitted:
            self.send_json(429, {"error": "tenant_concurrency_limit", "request_id": request_id, "capacity": self.ledger.args.capacity})
            return
        time.sleep(self.ledger.args.request_seconds)
        canonical = json.dumps(case, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256((canonical + model).encode()).hexdigest()
        completed_at = self.ledger.finish(request_id, owner, cohort, case_id, admitted_at)
        self.send_json(200, {
            "request_id": request_id,
            "case_id": case_id,
            "model": model,
            "schema_valid": True,
            "schema_digest": digest,
            "admitted_at_ns": admitted_at,
            "completed_at_ns": completed_at,
        })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--capacity", type=int, required=True)
    parser.add_argument("--request-seconds", type=float, required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--events-file", required=True)
    args = parser.parse_args()
    pathlib.Path(args.events_file).write_text("")
    ledger = Ledger(args)
    Handler.ledger = ledger
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    while not stop.wait(0.1):
        pass
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)


if __name__ == "__main__":
    main()

