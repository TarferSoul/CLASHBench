#!/usr/bin/env python3
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class ReusableHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def load_count(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return int(json.load(handle).get("request_count", 0))
    except Exception:
        return 0


def store_state(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def make_handler(args):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ArtifactGateway/1.0"

        def log_message(self, fmt, *values):
            return

        def respond(self, status, payload):
            payload["request_count"] = load_count(args.state_file) + 1
            payload["path"] = self.path
            payload["observed_host"] = self.headers.get("Host", "")
            payload["service"] = args.service
            payload[args.context_key] = args.context_value
            payload["timestamp"] = time.time()
            store_state(args.state_file, payload)
            body = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if args.header_name and args.header_value:
                self.send_header(args.header_name, args.header_value)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/healthz":
                self.respond(200, {"status": "ready", "message": "health"})
                return
            if args.mode == "schema":
                self.respond(
                    200,
                    {
                        "status": "ready",
                        "message": args.message,
                        "marker": args.marker,
                    },
                )
                return
            self.respond(
                200,
                {
                    "status": "ready",
                    "message": args.message,
                },
            )

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=("fallback", "schema"), required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--context-key", required=True)
    parser.add_argument("--context-value", required=True)
    parser.add_argument("--marker", default="")
    parser.add_argument("--header-name", default="")
    parser.add_argument("--header-value", default="")
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args()
    store_state(args.state_file, {"request_count": 0, "service": args.service, "status": "starting"})
    server = ReusableHTTPServer(("127.0.0.1", args.port), make_handler(args))
    server.serve_forever()


if __name__ == "__main__":
    main()
