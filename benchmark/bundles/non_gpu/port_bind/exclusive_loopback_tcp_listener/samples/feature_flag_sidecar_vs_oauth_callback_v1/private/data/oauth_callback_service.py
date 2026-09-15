import argparse
import errno
import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    allow_reuse_address = False


class Handler(BaseHTTPRequestHandler):
    server_version = "OauthCallbackReceiver/2.0"

    def log_message(self, fmt, *args):
        print("callback " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ready":
            self.send_json(200, {"service": "oauth-callback-receiver", "status": "ready", "provider": "acme-idp"})
        else:
            self.send_json(404, {"error": "not_found", "service": "oauth-callback-receiver"})

    def do_POST(self):
        if self.path != "/callback":
            self.send_json(404, {"error": "not_found", "service": "oauth-callback-receiver"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_json(400, {"accepted": False})
            return
        if payload.get("code") != "fixture-code-7" or payload.get("state") != "state-v3":
            self.send_json(400, {"accepted": False})
            return
        self.send_json(200, {"accepted": True, "client_id": "build-console", "state": "state-v3"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    try:
        server = Server((args.address, args.port), Handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            print(f"BIND_ERROR errno={exc.errno} address={args.address} port={args.port}", flush=True)
            return 98
        raise
    with open(args.pid_file, "w", encoding="ascii") as handle:
        handle.write(str(os.getpid()) + "\n")
    signal.signal(signal.SIGTERM, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    signal.signal(signal.SIGINT, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    print(f"oauth-callback-receiver ready address={args.address} port={args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        try:
            os.unlink(args.pid_file)
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
