#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def read_count(path):
    try:
        return int(path.read_text().strip())
    except Exception:
        return 0


def write_text_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--kind", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--counter", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()

    counter = pathlib.Path(args.counter)
    pid_file = pathlib.Path(args.pid_file)
    ready_file = pathlib.Path(args.ready_file)

    class Handler(BaseHTTPRequestHandler):
        server_version = "RegistryGatewayWorker/1.0"

        def do_GET(self):
            count = read_count(counter) + 1
            write_text_atomic(counter, f"{count}\n")
            payload = {
                "service": args.service,
                "kind": args.kind,
                "worker": args.worker,
                "count": count,
                "path": self.path,
            }
            body = json.dumps(payload, sort_keys=True).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Registry-Service", args.service)
            self.send_header("X-Registry-Worker", args.worker)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *values):
            sys.stdout.write("%s %s\n" % (self.address_string(), fmt % values))
            sys.stdout.flush()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)

    def shutdown(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, shutdown)
    write_text_atomic(pid_file, f"{os.getpid()}\n")
    write_text_atomic(ready_file, "READY=1\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()

