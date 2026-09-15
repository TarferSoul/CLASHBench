#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(131072), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path = pathlib.Path(path)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--lease", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args()
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    lock = threading.Lock()
    state = {"pid": os.getpid(), "revision": manifest["revision"], "lease": args.lease, "warm_hits": 0}
    held_files = []

    def verify():
        lease_path = pathlib.Path(args.cache) / "leases" / f"{args.lease}.json"
        if not lease_path.is_file():
            return False
        lease = json.loads(lease_path.read_text())
        expected = [item["sha256"] for item in manifest["artifacts"]]
        if lease.get("digests") != expected or lease.get("holder_pid") != os.getpid():
            return False
        for item in manifest["artifacts"]:
            path = pathlib.Path(args.cache) / "blobs" / "sha256" / item["sha256"]
            if not path.is_file() or path.stat().st_size != item["size"] or sha256(path) != item["sha256"]:
                return False
        return True

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def respond(self, status, payload):
            body = json.dumps(payload, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path)
            healthy = verify()
            if parsed.path == "/healthz":
                with lock:
                    payload = {**state, "warm_ready": healthy, "open_shards": len(held_files)}
                    write_json(args.state_file, payload)
                self.respond(200 if healthy else 503, payload)
                return
            if parsed.path == "/embed" and healthy:
                text = parse_qs(parsed.query).get("text", [""])[0]
                with lock:
                    state["warm_hits"] += 1
                    vector = hashlib.sha256((manifest["revision"] + ":" + text).encode()).hexdigest()[:24]
                    payload = {**state, "warm_ready": True, "open_shards": len(held_files), "vector": vector}
                    write_json(args.state_file, payload)
                self.respond(200, payload)
                return
            self.respond(503 if not healthy else 404, {"warm_ready": healthy})

    for item in manifest["artifacts"]:
        held_files.append((pathlib.Path(args.cache) / "blobs" / "sha256" / item["sha256"]).open("rb"))
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    write_json(args.state_file, {**state, "warm_ready": False, "open_shards": len(held_files)})
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    server.serve_forever(poll_interval=0.1)
    server.server_close()
    for handle in held_files:
        handle.close()


if __name__ == "__main__":
    main()
