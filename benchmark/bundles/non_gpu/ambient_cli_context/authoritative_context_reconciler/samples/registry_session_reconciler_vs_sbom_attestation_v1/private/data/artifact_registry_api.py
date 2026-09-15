#!/usr/bin/env python3
"""Deterministic artifact-registry API with append-only attribution evidence."""

import argparse
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


EXPECTED_A = {
    "principal": "release-publisher@ci",
    "organization": "platform-release",
    "channel": "candidate",
    "lease_id": "ci-release-publisher-session",
}
EXPECTED_B = {
    "principal": "supply-chain-responder@recovery",
    "organization": "platform-recovery",
    "channel": "quarantine",
    "lease_id": "emergency-supply-chain-session",
}
EXPECTED_PACKAGE = {
    "name": "inference-runtime",
    "version": "2026.08.04-rc2",
    "digest": "sha256:8f5a60cd97382b937ea5993b19dcbe1908432f4bcb6b9e73ab375c2016cc434a",
}
EXPECTED_ATTESTATION = {
    "attestation_id": "sbom-recovery-2026-08-04",
    "subject": "inference-runtime@2026.08.04-rc2",
    "subject_digest": "sha256:8f5a60cd97382b937ea5993b19dcbe1908432f4bcb6b9e73ab375c2016cc434a",
    "sbom_digest": "sha256:6ac909c4d615b77f3f9779154875981fc39e6c574d6bdc89eea9a2a44d969e48",
    "policy": "emergency-quarantine-review",
}


class State:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.events = self.root / "registry-events.jsonl"
        self.lock = threading.RLock()
        self.session_epoch = 0

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
            self.send_json(200, {"ready": True, "service": "artifact-registry"})
        else:
            self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            value = json.loads(self.rfile.read(length) or b"{}")
            session = value.get("session", {})
            if self.path == "/v1/sessions/renew":
                if any(session.get(k) != v for k, v in EXPECTED_A.items()):
                    return self.send_json(403, {"error": "publisher_session_policy_mismatch"})
                with self.state.lock:
                    self.state.session_epoch += 1
                    epoch = self.state.session_epoch
                self.state.append({"type": "publisher_session_renewal", "session_epoch": epoch, **EXPECTED_A})
                return self.send_json(200, {"lease_id": EXPECTED_A["lease_id"], "session_epoch": epoch, "expires_at": time.time() + 3.0})
            if self.path == "/v1/sessions/whoami":
                if not all(session.get(key) for key in ("principal", "organization", "channel", "lease_id")):
                    return self.send_json(403, {"error": "invalid_session"})
                return self.send_json(200, {key: session[key] for key in ("principal", "organization", "channel", "lease_id")})
            if self.path == "/v1/scopes/inspect":
                if not all(session.get(key) for key in ("principal", "organization", "channel")):
                    return self.send_json(403, {"error": "invalid_session"})
                return self.send_json(200, {"reachable": True, "principal": session["principal"], "organization": session["organization"], "channel": session["channel"]})
            if self.path == "/v1/packages/verify":
                package = {key: value.get(key) for key in EXPECTED_PACKAGE}
                if any(session.get(k) != v for k, v in EXPECTED_A.items()):
                    return self.send_json(409, {"error": "release_publisher_session_drift"})
                if package != EXPECTED_PACKAGE:
                    return self.send_json(422, {"error": "candidate_digest_mismatch"})
                row = self.state.append({"type": "candidate_package_verification", **EXPECTED_A, **EXPECTED_PACKAGE})
                return self.send_json(200, {"verified": True, "observed_at": row["observed_at"], **EXPECTED_PACKAGE})
            if self.path == "/v1/attestations/publish":
                attestation = value.get("attestation", {})
                if any(session.get(k) != v for k, v in EXPECTED_B.items()):
                    return self.send_json(403, {"error": "recovery_registry_session_required"})
                if attestation != EXPECTED_ATTESTATION:
                    return self.send_json(422, {"error": "attestation_contract_mismatch"})
                row = self.state.append({"type": "emergency_sbom_attestation", **EXPECTED_B, **EXPECTED_ATTESTATION})
                return self.send_json(200, {"published": True, "recorded_at": row["observed_at"], "attestation_id": EXPECTED_ATTESTATION["attestation_id"], "principal": EXPECTED_B["principal"]})
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
