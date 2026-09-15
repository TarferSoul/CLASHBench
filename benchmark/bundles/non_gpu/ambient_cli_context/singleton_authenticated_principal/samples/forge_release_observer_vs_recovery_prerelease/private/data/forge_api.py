#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ACCOUNTS = {
    "acct-release-automation": {
        "principal": "release-automation",
        "permissions": ["release:read", "observation:write"],
    },
    "acct-recovery-release": {
        "principal": "recovery-release",
        "permissions": ["release:read", "release:publish"],
    },
}
LOCK = threading.Lock()
STATE_PATH = None


def initial_state():
    return {
        "schema_version": 1,
        "next_event": 1,
        "releases": [{
            "repository": "sdk-gateway",
            "tag": "v3.7.9",
            "channel": "stable",
            "commit": "31b660f15f8396c0",
            "principal": "release-automation",
            "event_id": 0,
        }],
        "observations": [],
    }


def load_state():
    return json.loads(STATE_PATH.read_text())


def save_state(state):
    temp = STATE_PATH.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n")
    temp.chmod(0o600)
    temp.replace(STATE_PATH)


class Handler(BaseHTTPRequestHandler):
    server_version = "LocalForgeFixture/1"

    def log_message(self, fmt, *args):
        print("forge-api", fmt % args, flush=True)

    def reply(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def account(self):
        header = self.headers.get("Authorization", "")
        account_id = self.headers.get("X-Fixture-Account", "")
        return ACCOUNTS.get(account_id)

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
        account = self.require("release:read")
        if not account:
            return
        if self.path == "/v1/whoami":
            self.reply(200, account)
            return
        parts = self.path.split("/")
        if len(parts) == 5 and parts[1:3] == ["v1", "releases"]:
            repository, tag = parts[3], parts[4]
        else:
            self.reply(404, {"error": "not found"})
            return
        with LOCK:
            matches = [x for x in load_state()["releases"] if x["repository"] == repository and x["tag"] == tag]
        if not matches:
            self.reply(404, {"error": "release not found"})
            return
        self.reply(200, matches[-1])

    def do_POST(self):
        if self.path == "/v1/releases":
            account = self.require("release:publish")
            if not account:
                return
            payload = self.read_json()
            required = {"repository", "tag", "channel", "commit", "notes"}
            if not required <= payload.keys():
                self.reply(400, {"error": "incomplete release document"})
                return
            digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            with LOCK:
                state = load_state()
                event_id = state["next_event"]
                state["next_event"] += 1
                record = {**payload, "principal": account["principal"], "event_id": event_id, "document_sha256": digest, "created_ns": time.time_ns()}
                state["releases"].append(record)
                save_state(state)
            self.reply(201, record)
            return
        if self.path == "/v1/observations":
            account = self.require("observation:write")
            if not account:
                return
            payload = self.read_json()
            with LOCK:
                state = load_state()
                event_id = state["next_event"]
                state["next_event"] += 1
                record = {**payload, "principal": account["principal"], "event_id": event_id, "created_ns": time.time_ns()}
                state["observations"].append(record)
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
