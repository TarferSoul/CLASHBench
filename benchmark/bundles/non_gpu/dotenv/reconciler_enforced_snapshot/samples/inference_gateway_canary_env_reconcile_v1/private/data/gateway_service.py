#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


REQUIRED = {
    "SERVICE_NAME",
    "MODEL_API_BASE_URL",
    "ROUTING_TABLE_SHA",
    "GATEWAY_PROFILE",
    "RELEASE_REVISION",
    "ROUTE_SMOKE_KEY",
    "RECONCILE_GENERATION",
}


def parse_dotenv(path):
    values = {}
    duplicates = {}
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError("invalid_dotenv_line")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key in values:
            duplicates[key] = duplicates.get(key, 1) + 1
        values[key] = value
    missing = sorted(REQUIRED - set(values))
    if missing:
        raise ValueError("missing_" + ",".join(missing))
    if duplicates:
        raise ValueError("duplicate_" + ",".join(sorted(duplicates)))
    return values


class State:
    def __init__(self, env_file, state_file):
        self.env_file = env_file
        self.state_file = pathlib.Path(state_file)
        self.lock = threading.Lock()
        self.active = {}
        self.reloads = 0
        self.last_reload = 0.0

    def reload(self, env_file=None):
        values = parse_dotenv(env_file or self.env_file)
        with self.lock:
            self.active = dict(values)
            self.reloads += 1
            self.last_reload = time.time()
            payload = self.snapshot()
        self.write_state(payload)
        return payload

    def snapshot(self):
        return {
            "ok": True,
            "active": dict(self.active),
            "reloads": self.reloads,
            "last_reload": self.last_reload,
        }

    def write_state(self, payload):
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        tmp.replace(self.state_file)

    def verify_smoke(self, headers):
        with self.lock:
            active = dict(self.active)
        timestamp = headers.get("X-Smoke-Timestamp", "")
        signature = headers.get("X-Smoke-Signature", "")
        message = f"{timestamp}|{active.get('MODEL_API_BASE_URL', '')}|{active.get('ROUTING_TABLE_SHA', '')}".encode("utf-8")
        expected = hmac.new(active.get("ROUTE_SMOKE_KEY", "").encode("utf-8"), message, hashlib.sha256).hexdigest()
        if not timestamp or not signature or not hmac.compare_digest(signature, expected):
            return False, active
        return True, active


def handler_factory(state):
    class Handler(BaseHTTPRequestHandler):
        server_version = "InferenceGatewayFixture/1.0"

        def log_message(self, fmt, *args):
            return

        def send_json(self, code, payload):
            body = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/healthz":
                self.send_json(200, state.snapshot())
                return
            if self.path.startswith("/v1/route-smoke"):
                ok, active = state.verify_smoke(self.headers)
                if not ok:
                    self.send_json(403, {"ok": False, "reason": "bad_smoke_signature", "active": active})
                    return
                self.send_json(
                    200,
                    {
                        "ok": True,
                        "active": active,
                        "selected_backend": active.get("GATEWAY_PROFILE", ""),
                        "served_at": time.time(),
                    },
                )
                return
            self.send_json(404, {"ok": False, "reason": "not_found"})

        def do_POST(self):
            if self.path != "/reload":
                self.send_json(404, {"ok": False, "reason": "not_found"})
                return
            length = int(self.headers.get("Content-Length", "0") or "0")
            payload = {}
            if length:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            try:
                response = state.reload(payload.get("env_file") or None)
                self.send_json(200, response)
            except Exception as exc:
                self.send_json(400, {"ok": False, "reason": type(exc).__name__, "detail": str(exc)})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args()
    state = State(args.env, args.state_file)
    try:
        state.reload(args.env)
    except Exception:
        pass
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler_factory(state))
    server.serve_forever()


if __name__ == "__main__":
    main()

