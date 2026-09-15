#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import credential_material as material


class Handler(BaseHTTPRequestHandler):
    policy = {}
    audit_file = pathlib.Path("/run/feature_store_token/api_audit.jsonl")

    def log_message(self, fmt, *args):
        return

    def write_json(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def credential_from_headers(self):
        auth = self.headers.get("Authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        return {
            "FEATURE_STORE_TOKEN": token,
            "FEATURE_STORE_TOKEN_EXPIRES_AT": self.headers.get("X-Feature-Token-Expires-At", ""),
            "FEATURE_STORE_LEASE_ID": self.headers.get("X-Feature-Lease-Id", ""),
            "FEATURE_STORE_AUDIENCE": self.headers.get("X-Feature-Audience", ""),
            "RECONCILE_GENERATION": self.headers.get("X-Feature-Reconcile-Generation", ""),
        }

    def audit(self, payload):
        payload = {**payload, "at": time.time(), "path": self.path}
        with self.audit_file.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, sort_keys=True) + "\n")

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self.write_json(200, {"ok": True, "service": "feature-store-fixture"})
            return
        if parsed.path == "/probe" or parsed.path.startswith("/export/page/"):
            values = self.credential_from_headers()
            ok, reason = material.validate_tuple(self.policy, values)
            code = 200 if ok else 401
            page = None
            if parsed.path.startswith("/export/page/"):
                try:
                    page = int(parsed.path.rsplit("/", 1)[1])
                except ValueError:
                    ok, reason, code = False, "bad_page", 400
            payload = {
                "ok": ok,
                "reason": reason,
                "audience": values.get("FEATURE_STORE_AUDIENCE", ""),
                "lease_id": values.get("FEATURE_STORE_LEASE_ID", ""),
                "generation": values.get("RECONCILE_GENERATION", ""),
                "page": page,
                "issued_at": time.time(),
            }
            self.audit(payload)
            self.write_json(code, payload)
            return
        self.write_json(404, {"ok": False, "reason": "not_found"})


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--policy")
    source.add_argument("--policy-fd", type=int)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--audit-file", required=True)
    args = parser.parse_args()
    if args.policy_fd is not None:
        with os.fdopen(args.policy_fd, "r", encoding="utf-8") as handle:
            Handler.policy = json.load(handle)
    else:
        Handler.policy = material.load_policy(args.policy)
    Handler.audit_file = pathlib.Path(args.audit_file)
    Handler.audit_file.parent.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    main()
