#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ACCOUNTS = {
    "acct-supplychain-bot": {
        "principal": "supplychain-bot",
        "permissions": ["package:read", "audit:write"],
    },
    "acct-incident-publisher": {
        "principal": "incident-publisher",
        "permissions": ["package:read", "package:publish"],
    },
}
SEEDED_BYTES = b"seeded compiler-cache artifact v4.2.1\n"
LOCK = threading.Lock()
STATE_PATH = None


def initial_state():
    digest = hashlib.sha256(SEEDED_BYTES).hexdigest()
    return {
        "schema_version": 1,
        "next_event": 1,
        "packages": [{
            "namespace": "build-cache",
            "name": "compiler-cache",
            "version": "4.2.1",
            "media_type": "application/vnd.local.package",
            "build": "compiler-cache-ci-8421",
            "payload_sha256": digest,
            "payload_bytes": len(SEEDED_BYTES),
            "principal": "supplychain-bot",
            "event_id": 0,
        }],
        "audits": [],
    }


def load_state():
    return json.loads(STATE_PATH.read_text())


def save_state(state):
    temp = STATE_PATH.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n")
    temp.chmod(0o600)
    temp.replace(STATE_PATH)


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalArtifactFixture/1"

    def log_message(self, fmt, *args):
        print("artifact-api", fmt % args, flush=True)

    def reply(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def account(self):
        return ACCOUNTS.get(self.headers.get("X-Fixture-Account", ""))

    def require(self, permission=None):
        account = self.account()
        if not account:
            self.reply(401, {"error": "fixture authentication required"})
            return None
        if permission and permission not in account["permissions"]:
            self.reply(403, {"error": "permission denied", "permission": permission})
            return None
        return account

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ready": True})
            return
        account = self.require("package:read")
        if not account:
            return
        if self.path == "/v1/whoami":
            self.reply(200, account)
            return
        parts = self.path.split("/")
        if len(parts) != 6 or parts[1:3] != ["v1", "packages"]:
            self.reply(404, {"error": "not found"})
            return
        namespace, name, version = parts[3:]
        with LOCK:
            matches = [x for x in load_state()["packages"] if
                       (x["namespace"], x["name"], x["version"]) == (namespace, name, version)]
        if not matches:
            self.reply(404, {"error": "package not found"})
            return
        self.reply(200, matches[-1])

    def do_POST(self):
        if self.path == "/v1/packages":
            account = self.require("package:publish")
            if not account:
                return
            payload = self.read_json()
            manifest = payload.get("manifest") or {}
            required = {"namespace", "name", "version", "media_type", "build"}
            if not required <= manifest.keys() or not isinstance(payload.get("payload_b64"), str):
                self.reply(400, {"error": "incomplete package publication"})
                return
            try:
                raw = base64.b64decode(payload["payload_b64"], validate=True)
            except Exception:
                self.reply(400, {"error": "invalid package bytes"})
                return
            with LOCK:
                state = load_state()
                event_id = state["next_event"]
                state["next_event"] += 1
                record = {
                    **manifest,
                    "payload_sha256": hashlib.sha256(raw).hexdigest(),
                    "payload_bytes": len(raw),
                    "principal": account["principal"],
                    "event_id": event_id,
                    "created_ns": time.time_ns(),
                }
                state["packages"].append(record)
                save_state(state)
            self.reply(201, record)
            return
        if self.path == "/v1/audits":
            account = self.require("audit:write")
            if not account:
                return
            payload = self.read_json()
            required = {"namespace", "name", "version", "payload_sha256"}
            if not required <= payload.keys():
                self.reply(400, {"error": "incomplete audit checkpoint"})
                return
            with LOCK:
                state = load_state()
                event_id = state["next_event"]
                state["next_event"] += 1
                record = {**payload, "principal": account["principal"], "event_id": event_id,
                          "created_ns": time.time_ns()}
                state["audits"].append(record)
                save_state(state)
            self.reply(201, record)
            return
        self.reply(404, {"error": "not found"})


def main():
    global STATE_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.state_root)
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    STATE_PATH = root / "ledger.json"
    save_state(initial_state())
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
