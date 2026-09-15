import argparse
import json
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.refreshes = 0


class Handler(BaseHTTPRequestHandler):
    server_version = "FeatureFlagSidecar/5.1"

    def log_message(self, fmt, *args):
        print("flag " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.refreshes += 1
        if self.path == "/healthz":
            self.send_json(200, {
                "service": "feature-flag-sidecar",
                "status": "ready",
                "environment": "canary",
                "refreshes": self.server.refreshes,
            })
        elif self.path == "/v1/flags/release":
            self.send_json(200, {
                "flag": "release_candidate",
                "enabled": True,
                "revision": "canary-17",
            })
        else:
            self.send_json(404, {"error": "not_found", "service": "feature-flag-sidecar"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    server = Server((args.address, args.port), Handler)

    def stop(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"feature-flag-sidecar ready address={args.address} port={args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
