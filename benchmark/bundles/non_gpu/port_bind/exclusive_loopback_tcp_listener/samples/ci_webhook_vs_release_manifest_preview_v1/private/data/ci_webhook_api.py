import argparse
import json
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    allow_reuse_address = False

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.events_received = 0


class Handler(BaseHTTPRequestHandler):
    server_version = "CiWebhookReceiver/3.2"

    def log_message(self, fmt, *args):
        print("delivery " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {
                "service": "ci-webhook-receiver",
                "status": "ready",
                "workspace": "release-pipeline",
                "events_received": self.server.events_received,
            })
        elif self.path == "/v1/events":
            self.send_json(200, {
                "accepted": self.server.events_received,
                "stream": "deployment-callbacks",
            })
        else:
            self.send_json(404, {"error": "not_found", "service": "ci-webhook-receiver"})

    def do_POST(self):
        if self.path != "/v1/events":
            self.send_json(404, {"error": "not_found", "service": "ci-webhook-receiver"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            event = json.loads(body)
        except json.JSONDecodeError:
            self.send_json(400, {"accepted": False})
            return
        if event.get("kind") != "deployment":
            self.send_json(422, {"accepted": False})
            return
        self.server.events_received += 1
        self.send_json(202, {"accepted": True, "sequence": self.server.events_received})


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
    print(f"ci-webhook-receiver ready address={args.address} port={args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
