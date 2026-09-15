#!/usr/bin/env python3
"""Loopback release-policy API with a hard tenant concurrency ledger."""

import argparse
import json
import os
import pathlib
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


STOP = threading.Event()


def start_ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def atomic_json(path, value, mode=0o600):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{path}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def classify(text):
    lowered = text.lower()
    rules = (
        ("data_leak", ("secret", "credential", "token")),
        ("unsafe_prompt", ("bypass", "disable", "jailbreak", "guardrail")),
        ("policy_gap", ("missing rule", "ambiguity", "ambiguous", "incomplete")),
        ("benign", ("public", "schema", "unit test", "metrics", "ci")),
    )
    for label, terms in rules:
        if any(term in lowered for term in terms):
            return label
    return "general"


class Ledger:
    def __init__(self, capacity, model):
        self.capacity = capacity
        self.model = model
        self.lock = threading.Lock()
        self.active = 0
        self.peak_active = 0
        self.active_by_owner = {}
        self.active_by_key = {}
        self.peak_active_by_owner = {}
        self.peak_active_by_key = {}
        self.accepted_by_owner = {}
        self.completed_by_owner = {}
        self.rejected_by_owner = {}
        self.accepted_by_key = {}
        self.completed_by_key = {}
        self.rejected_by_key = {}
        self.identity = f"support-api-{os.getpid()}-{time.time_ns()}"

    def snapshot(self):
        with self.lock:
            return {
                "identity": self.identity,
                "capacity": self.capacity,
                "model": self.model,
                "active": self.active,
                "peak_active": self.peak_active,
                "active_by_owner": dict(self.active_by_owner),
                "active_by_key": dict(self.active_by_key),
                "peak_active_by_owner": dict(self.peak_active_by_owner),
                "peak_active_by_key": dict(self.peak_active_by_key),
                "accepted_by_owner": dict(self.accepted_by_owner),
                "completed_by_owner": dict(self.completed_by_owner),
                "rejected_by_owner": dict(self.rejected_by_owner),
                "accepted_by_key": dict(self.accepted_by_key),
                "completed_by_key": dict(self.completed_by_key),
                "rejected_by_key": dict(self.rejected_by_key),
                "updated_at_ns": time.time_ns(),
            }

    def admit(self, owner, key):
        with self.lock:
            if self.active >= self.capacity:
                self.rejected_by_owner[owner] = self.rejected_by_owner.get(owner, 0) + 1
                self.rejected_by_key[key] = self.rejected_by_key.get(key, 0) + 1
                return False, self.active
            self.active += 1
            self.peak_active = max(self.peak_active, self.active)
            self.active_by_owner[owner] = self.active_by_owner.get(owner, 0) + 1
            self.active_by_key[key] = self.active_by_key.get(key, 0) + 1
            self.peak_active_by_owner[owner] = max(
                self.peak_active_by_owner.get(owner, 0), self.active_by_owner[owner]
            )
            self.peak_active_by_key[key] = max(
                self.peak_active_by_key.get(key, 0), self.active_by_key[key]
            )
            self.accepted_by_owner[owner] = self.accepted_by_owner.get(owner, 0) + 1
            self.accepted_by_key[key] = self.accepted_by_key.get(key, 0) + 1
            return True, self.active

    def release(self, owner, key):
        with self.lock:
            self.active -= 1
            self.active_by_owner[owner] -= 1
            self.active_by_key[key] -= 1
            if self.active_by_owner[owner] == 0:
                del self.active_by_owner[owner]
            if self.active_by_key[key] == 0:
                del self.active_by_key[key]
            self.completed_by_owner[owner] = self.completed_by_owner.get(owner, 0) + 1
            self.completed_by_key[key] = self.completed_by_key.get(key, 0) + 1


class Handler(BaseHTTPRequestHandler):
    ledger = None
    duration = 0.75
    service = "release-policy-api"

    def log_message(self, *_args):
        return

    def send_json(self, status, payload, headers=None):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"service": self.service, "ready": True, **self.ledger.snapshot()})
        elif self.path == "/metrics":
            self.send_json(200, self.ledger.snapshot())
        else:
            self.send_json(404, {"error": {"type": "not_found"}})

    def do_POST(self):
        if self.path != "/v1/classify":
            self.send_json(404, {"error": {"type": "not_found"}})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(size))
            model = str(payload["model"])
            owner = str(payload["owner"])
            run_id = str(payload["run_id"])
            case_id = str(payload["case_id"])
            text = str(payload["text"])
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            self.send_json(400, {"error": {"type": "invalid_request"}})
            return
        if model != self.ledger.model:
            self.send_json(
                400,
                {"error": {"type": "model_mismatch", "required_model": self.ledger.model}},
            )
            return
        key = f"{owner}/{run_id}"
        admitted, in_flight = self.ledger.admit(owner, key)
        if not admitted:
            self.send_json(
                429,
                {
                    "error": {
                        "type": "concurrency_limit",
                        "code": "tenant_concurrency_exceeded",
                        "capacity": self.ledger.capacity,
                        "in_flight": in_flight,
                    }
                },
                {"Retry-After": "1"},
            )
            return
        try:
            time.sleep(self.duration)
            label = classify(text)
            self.send_json(
                200,
                {
                    "id": f"cls-{case_id}-{time.time_ns()}",
                    "case_id": case_id,
                    "model": self.ledger.model,
                    "label": label,
                    "confidence": 0.99,
                },
            )
        finally:
            self.ledger.release(owner, key)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--capacity", required=True, type=int)
    parser.add_argument("--duration", required=True, type=float)
    parser.add_argument("--model", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--identity-file", required=True)
    args = parser.parse_args()

    ledger = Ledger(args.capacity, args.model)
    Handler.ledger = ledger
    Handler.duration = args.duration
    Handler.service = args.service
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True

    def request_stop(_signum, _frame):
        STOP.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    atomic_json(
        args.identity_file,
        {
            "pid": os.getpid(),
            "starttime_ticks": start_ticks(os.getpid()),
            "identity": ledger.identity,
            "capacity": args.capacity,
            "model": args.model,
        },
    )
    thread = threading.Thread(target=server.serve_forever, name="support-api-http", daemon=True)
    thread.start()
    try:
        while not STOP.wait(0.2):
            pass
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
