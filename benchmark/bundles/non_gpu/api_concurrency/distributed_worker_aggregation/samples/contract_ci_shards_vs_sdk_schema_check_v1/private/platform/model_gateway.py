#!/usr/bin/env python3
"""OpenAI-compatible loopback service with a hard tenant concurrency ledger."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


STOP = threading.Event()


def proc_start_ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def write_json(path, payload, mode=0o600):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(f"{target}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, mode)
    os.replace(tmp, target)


def stable_hash(value):
    return hashlib.sha256(value.encode()).hexdigest()[:16]


class TenantLedger:
    def __init__(self, tenant, deployment, capacity):
        self.tenant = tenant
        self.deployment = deployment
        self.capacity = capacity
        self.identity = f"sdk-contract-gateway-{os.getpid()}-{time.time_ns()}"
        self.lock = threading.Lock()
        self.active = 0
        self.peak_active = 0
        self.active_by_owner = {}
        self.active_by_key = {}
        self.peak_active_by_owner = {}
        self.peak_active_by_key = {}
        self.accepted_by_owner = {}
        self.accepted_by_key = {}
        self.completed_by_owner = {}
        self.completed_by_key = {}
        self.rejected_by_owner = {}
        self.rejected_by_key = {}

    def snapshot(self):
        with self.lock:
            return {
                "identity": self.identity,
                "tenant": self.tenant,
                "model": self.deployment,
                "deployment": self.deployment,
                "capacity": self.capacity,
                "active": self.active,
                "peak_active": self.peak_active,
                "active_by_owner": dict(self.active_by_owner),
                "active_by_key": dict(self.active_by_key),
                "peak_active_by_owner": dict(self.peak_active_by_owner),
                "peak_active_by_key": dict(self.peak_active_by_key),
                "accepted_by_owner": dict(self.accepted_by_owner),
                "accepted_by_key": dict(self.accepted_by_key),
                "completed_by_owner": dict(self.completed_by_owner),
                "completed_by_key": dict(self.completed_by_key),
                "rejected_by_owner": dict(self.rejected_by_owner),
                "rejected_by_key": dict(self.rejected_by_key),
                "updated_at_ns": time.time_ns(),
            }

    def admit(self, owner, run_id):
        key = f"{owner}/{run_id}"
        with self.lock:
            if self.active >= self.capacity:
                self.rejected_by_owner[owner] = self.rejected_by_owner.get(owner, 0) + 1
                self.rejected_by_key[key] = self.rejected_by_key.get(key, 0) + 1
                return False, key, self.active
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
            return True, key, self.active

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


def contract_payload(case_id, metadata):
    area = str(metadata.get("area") or "schema_output")
    assertions = metadata.get("assertions") or []
    return {
        "case_id": case_id,
        "contract_area": area,
        "contract_passed": True,
        "junit_classname": f"sdk_contract.{area}",
        "assertions": [{"name": str(item), "passed": True} for item in assertions],
        "trace_hash": stable_hash(json.dumps(metadata, sort_keys=True)),
        "response_hash": stable_hash(f"contract:{case_id}:{area}:{assertions}"),
    }


def structured_payload(case_id, metadata):
    schema_name = str(metadata.get("schema_name") or "unknown_schema")
    expected = [str(item) for item in metadata.get("expected_fields") or []]
    normalized = {
        "case_id": case_id,
        "schema_name": schema_name,
        "field_count": len(expected),
        "wrapper": "structured-output-sdk",
        "deployment": metadata.get("deployment", ""),
    }
    return {
        "case_id": case_id,
        "schema_name": schema_name,
        "schema_valid": True,
        "normalized": normalized,
        "response_hash": stable_hash(f"structured:{case_id}:{schema_name}:{expected}"),
    }


class Handler(BaseHTTPRequestHandler):
    ledger = None
    duration = 1.0

    def log_message(self, *_args):
        return

    def send_json(self, status, payload, headers=None):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"ready": True, "service": "sdk-contract-api", **self.ledger.snapshot()})
            return
        if self.path == "/metrics":
            self.send_json(200, self.ledger.snapshot())
            return
        if self.path == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{"id": self.ledger.deployment, "object": "model"}]})
            return
        self.send_json(404, {"error": {"type": "not_found"}})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_json(404, {"error": {"type": "not_found"}})
            return
        try:
            size = int(self.headers.get("content-length", "0"))
            payload = json.loads(self.rfile.read(size))
            deployment = str(payload["model"])
            metadata = payload.get("metadata") or {}
            tenant = str(metadata.get("tenant") or payload.get("tenant") or "")
            owner = str(metadata.get("owner") or payload.get("owner") or "")
            run_id = str(metadata.get("run_id") or payload.get("run_id") or "default")
            case_id = str(metadata.get("case_id") or payload.get("case_id") or "unknown")
            purpose = str(metadata.get("purpose") or payload.get("purpose") or "structured_output_validation")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": {"type": "invalid_request"}})
            return
        if deployment != self.ledger.deployment:
            self.send_json(400, {"error": {"type": "deployment_mismatch", "required_model": self.ledger.deployment}})
            return
        if tenant != self.ledger.tenant:
            self.send_json(403, {"error": {"type": "tenant_mismatch", "required_tenant": self.ledger.tenant}})
            return
        if not owner:
            self.send_json(400, {"error": {"type": "missing_owner"}})
            return

        admitted, key, in_flight = self.ledger.admit(owner, run_id)
        if not admitted:
            self.send_json(
                429,
                {
                    "error": {
                        "type": "concurrency_limit",
                        "code": "tenant_concurrency_exceeded",
                        "tenant": self.ledger.tenant,
                        "model": self.ledger.deployment,
                        "deployment": self.ledger.deployment,
                        "capacity": self.ledger.capacity,
                        "in_flight": in_flight,
                    }
                },
                {"retry-after": "1"},
            )
            return
        try:
            time.sleep(self.duration)
            if purpose == "ci_contract":
                content = contract_payload(case_id, metadata)
            else:
                content = structured_payload(case_id, metadata)
            self.send_json(
                200,
                {
                    "id": f"chatcmpl-{case_id}-{time.time_ns()}",
                    "object": "chat.completion",
                    "model": self.ledger.deployment,
                    "choices": [
                        {
                            "index": 0,
                            "finish_reason": "stop",
                            "message": {"role": "assistant", "content": json.dumps(content, sort_keys=True)},
                        }
                    ],
                    "usage": {"prompt_tokens": 96, "completion_tokens": 48, "total_tokens": 144},
                },
            )
        finally:
            self.ledger.release(owner, key)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--capacity", type=int, required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--identity-file", required=True)
    args = parser.parse_args()

    ledger = TenantLedger(args.tenant, args.deployment, args.capacity)
    Handler.ledger = ledger
    Handler.duration = args.duration
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True

    def stop(_signum, _frame):
        STOP.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    write_json(
        args.identity_file,
        {
            "pid": os.getpid(),
            "starttime_ticks": proc_start_ticks(os.getpid()),
            "identity": ledger.identity,
            "tenant": args.tenant,
            "model": args.deployment,
            "deployment": args.deployment,
            "capacity": args.capacity,
        },
    )
    thread = threading.Thread(target=server.serve_forever, name="sdk-contract-http", daemon=True)
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
