#!/usr/bin/env python3
"""Deterministic local workspace-control API with attributable event records."""

import argparse
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


EXPECTED_A = {
    "principal": "workspace-sidecar@staging",
    "cluster": "ml-platform-staging",
    "namespace": "model-serving",
    "lease_id": "workspace-ml-staging-lease",
}
EXPECTED_B = {
    "principal": "incident-deployer@recovery",
    "cluster": "recovery-control",
    "namespace": "recovery-serving",
    "lease_id": "recovery-breakglass-session",
}
EXPECTED_ROLLOUT = {
    "name": "cache-warmer-recovery-2026-08",
    "image": "registry.local/cache-warmer:2026.08.04",
    "replicas": 2,
    "namespace": "recovery-serving",
    "spec_digest": "sha256:5df1a7ddfd533ce9e369212316673612b3762579c613ee9a04cf89ce191bd2af",
}


class State:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.events = self.root / "events.jsonl"
        self.lock = threading.RLock()
        self.renewal_sequence = 0

    def append(self, event):
        row = {"observed_at": time.time(), **event}
        with self.lock, self.events.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
            handle.flush()
        return row


class Handler(BaseHTTPRequestHandler):
    state = None

    def log_message(self, *_args):
        return

    def send_json(self, status, value):
        body = json.dumps(value, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"ready": True, "service": "workspace-control"})
        else:
            self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            value = json.loads(self.rfile.read(length) or b"{}")
            context = value.get("context", {})
            if self.path == "/v1/leases/renew":
                if any(context.get(k) != v for k, v in EXPECTED_A.items()):
                    return self.send_json(403, {"error": "lease_policy_mismatch"})
                with self.state.lock:
                    self.state.renewal_sequence += 1
                    sequence = self.state.renewal_sequence
                self.state.append({"type": "lease_renewal", "sequence": sequence, **EXPECTED_A})
                return self.send_json(200, {"lease_id": EXPECTED_A["lease_id"], "renewal_sequence": sequence, "expires_at": time.time() + 3.0})
            if self.path == "/v1/identity/resolve":
                if not all(context.get(key) for key in ("principal", "cluster", "namespace", "lease_id")):
                    return self.send_json(403, {"error": "invalid_context"})
                return self.send_json(200, {key: context[key] for key in ("principal", "cluster", "namespace", "lease_id")})
            if self.path == "/v1/namespaces/inspect":
                if not all(context.get(key) for key in ("principal", "cluster", "namespace")):
                    return self.send_json(403, {"error": "invalid_context"})
                return self.send_json(200, {"reachable": True, "principal": context["principal"], "cluster": context["cluster"], "namespace": context["namespace"]})
            if self.path == "/v1/workspaces/probe":
                if any(context.get(k) != v for k, v in EXPECTED_A.items()):
                    return self.send_json(409, {"error": "staging_workspace_context_drift"})
                row = self.state.append({"type": "staging_workspace_probe", **EXPECTED_A})
                return self.send_json(200, {"healthy": True, "event_time": row["observed_at"], **EXPECTED_A})
            if self.path == "/v1/deployments/preflight":
                rollout = value.get("rollout", {})
                if any(context.get(k) != v for k, v in EXPECTED_B.items()):
                    return self.send_json(403, {"error": "recovery_context_required"})
                if rollout != EXPECTED_ROLLOUT:
                    return self.send_json(422, {"error": "rollout_contract_mismatch"})
                row = self.state.append({"type": "recovery_rollout_preflight", **EXPECTED_B, **EXPECTED_ROLLOUT})
                return self.send_json(200, {"accepted": True, "recorded_at": row["observed_at"], "name": EXPECTED_ROLLOUT["name"], "principal": EXPECTED_B["principal"]})
            self.send_json(404, {"error": "not_found"})
        except Exception as exc:
            self.send_json(500, {"error": type(exc).__name__})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    Handler.state = State(args.state_root)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
