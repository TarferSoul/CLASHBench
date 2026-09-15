#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Ledger:
    def __init__(self, capacity, tenant, deployment, state_path, audit_path):
        self.capacity = capacity
        self.tenant = tenant
        self.deployment = deployment
        self.state_path = pathlib.Path(state_path)
        self.audit_path = pathlib.Path(audit_path)
        self.lock = threading.Lock()
        self.requests = {}
        self.rejected = 0
        self.completed = 0
        self.started_at = time.time()
        self._write_state()

    def _payload(self):
        return {
            "tenant": self.tenant,
            "deployment": self.deployment,
            "capacity": self.capacity,
            "active_count": sum(1 for value in self.requests.values() if value["active"]),
            "rejected": self.rejected,
            "completed": self.completed,
            "started_at": self.started_at,
            "requests": self.requests,
            "updated_at": time.time(),
        }

    def _write_state(self):
        tmp = self.state_path.with_name(
            self.state_path.name + f".tmp.{os.getpid()}.{threading.get_ident()}"
        )
        tmp.write_text(json.dumps(self._payload(), sort_keys=True) + "\n")
        os.replace(tmp, self.state_path)

    def _audit(self, event, request):
        row = {
            "ts": time.time(),
            "event": event,
            "request_id": request.get("request_id"),
            "repository": request.get("repository"),
            "owner": request.get("owner"),
            "token_index": request.get("token_index", 0),
            "deployment": self.deployment,
            "active_total": sum(1 for value in self.requests.values() if value["active"]),
            "active_owner": sum(
                1
                for value in self.requests.values()
                if value["active"] and value["owner"] == request.get("owner")
            ),
        }
        with self.audit_path.open("a") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
            handle.flush()

    def admit(self, request_id, repository, source_digest, owner):
        with self.lock:
            request = {
                "request_id": request_id,
                "repository": repository,
                "source_digest": source_digest,
                "owner": owner,
                "deployment": self.deployment,
                "active": False,
                "token_index": 0,
                "admitted_at": None,
                "first_token_at": None,
                "completed_at": None,
                "released_at": None,
            }
            if sum(1 for value in self.requests.values() if value["active"]) >= self.capacity:
                self.rejected += 1
                self._audit("rejected", request)
                self._write_state()
                return False
            request["active"] = True
            request["admitted_at"] = time.time()
            self.requests[request_id] = request
            self._audit("admitted", request)
            self._write_state()
            return True

    def progress(self, request_id, token_index):
        with self.lock:
            request = self.requests[request_id]
            request["token_index"] = token_index
            if request["first_token_at"] is None:
                request["first_token_at"] = time.time()
                self._audit("first_token", request)
            self._write_state()

    def finish(self, request_id, completed):
        with self.lock:
            request = self.requests.get(request_id)
            if not request:
                return
            request["active"] = False
            request["released_at"] = time.time()
            if completed:
                request["completed_at"] = request["released_at"]
                self.completed += 1
                self._audit("completed", request)
            else:
                self._audit("released", request)
            self._write_state()

    def snapshot(self):
        with self.lock:
            return self._payload()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server_version = "PinnedReviewGateway/1.0"

    def log_message(self, fmt, *args):
        return

    def json_response(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.json_response(200, {"ok": True, **self.server.ledger.snapshot()})
        elif self.path == "/metrics":
            self.json_response(200, self.server.ledger.snapshot())
        else:
            self.json_response(404, {"error": {"code": "not_found"}})

    def do_POST(self):
        if self.path != "/v1/review":
            self.json_response(404, {"error": {"code": "not_found"}})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
            request_id = self.headers.get("X-Request-ID", "")
            owner = self.headers.get("X-Client-Owner", "")
            tenant = payload["tenant"]
            deployment = payload["deployment"]
            repository = payload["repository"]
            source_digest = payload["source_digest"]
            token_count = int(payload["token_count"])
            interval_ms = int(payload.get("interval_ms", 90))
        except Exception:
            self.json_response(400, {"error": {"code": "invalid_json_contract"}})
            return
        if (
            tenant != self.server.ledger.tenant
            or deployment != self.server.ledger.deployment
            or not request_id
            or not owner
            or not repository
            or not source_digest.startswith("sha256:")
            or token_count < 1
            or token_count > 20000
            or interval_ms < 20
            or interval_ms > 1000
        ):
            self.json_response(400, {"error": {"code": "invalid_contract"}})
            return
        if not self.server.ledger.admit(request_id, repository, source_digest, owner):
            self.json_response(
                429,
                {
                    "error": {
                        "code": "concurrency_limit",
                        "tenant": tenant,
                        "deployment": deployment,
                        "capacity": self.server.ledger.capacity,
                    }
                },
            )
            return
        completed = False
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            for token_index in range(1, token_count + 1):
                item = {
                    "type": "analysis_delta",
                    "request_id": request_id,
                    "repository": repository,
                    "token_index": token_index,
                    "finding_fragment": f"finding-{repository}-{token_index:05d}",
                }
                self.wfile.write((json.dumps(item, sort_keys=True) + "\n").encode())
                self.wfile.flush()
                self.server.ledger.progress(request_id, token_index)
                time.sleep(interval_ms / 1000.0)
            final = {
                "type": "analysis_complete",
                "response": {
                    "request_id": request_id,
                    "repository": repository,
                    "source_digest": source_digest,
                    "deployment": deployment,
                    "risk": "medium",
                    "findings": [f"validated-{repository}-interface", f"checked-{repository}-error-path"],
                    "compatibility": {"schema_version": 1, "status": "compatible"},
                },
            }
            self.wfile.write((json.dumps(final, sort_keys=True) + "\n").encode())
            self.wfile.flush()
            completed = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.server.ledger.finish(request_id, completed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--capacity", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--audit", required=True)
    args = parser.parse_args()
    ledger = Ledger(
        args.capacity, args.tenant, args.deployment, args.state, args.audit
    )
    server = Server((args.host, args.port), Handler)
    server.ledger = ledger
    server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
