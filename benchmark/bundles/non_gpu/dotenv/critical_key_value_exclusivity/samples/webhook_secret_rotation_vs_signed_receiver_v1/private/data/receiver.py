#!/usr/bin/env python3
"""Reloading local release-webhook receiver used by the incumbent workflow."""

import argparse
import hashlib
import hmac
import json
import pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def effective_value(path, wanted):
    found = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key.strip() == wanted:
            found.append(value)
    if len(found) != 1:
        raise ValueError(f"expected one {wanted} assignment")
    return found[0]


class Receiver(BaseHTTPRequestHandler):
    server_version = "ReleaseReceiver/1.0"

    def log_message(self, fmt, *args):
        return

    def reply(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/live":
            self.reply(404, {"error": "not-found"})
            return
        self.reply(200, {"service": "release-webhook-receiver", "state": "running"})

    def do_POST(self):
        if self.path != "/hooks/release":
            self.reply(404, {"error": "not-found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > 65536:
                raise ValueError("invalid body length")
            body = self.rfile.read(length)
            secret = effective_value(self.server.env_path, "WEBHOOK_SIGNING_SECRET")
            supplied = self.headers.get("X-Webhook-Signature", "")
            expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
            if not hmac.compare_digest(supplied, expected):
                self.reply(401, {"accepted": False, "reason": "signature-mismatch"})
                return
            event = json.loads(body)
            with self.server.delivery_log.open("a") as handle:
                handle.write(json.dumps({"event": event.get("event"), "release": event.get("release")}, sort_keys=True) + "\n")
            self.reply(202, {"accepted": True, "service": "release-webhook-receiver", "event": event.get("event")})
        except Exception as exc:
            self.reply(500, {"accepted": False, "reason": type(exc).__name__})


parser = argparse.ArgumentParser()
parser.add_argument("--address", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--env", required=True)
parser.add_argument("--delivery-log", required=True)
args = parser.parse_args()
server = ThreadingHTTPServer((args.address, args.port), Receiver)
server.env_path = pathlib.Path(args.env)
server.delivery_log = pathlib.Path(args.delivery_log)
server.serve_forever(poll_interval=0.1)
