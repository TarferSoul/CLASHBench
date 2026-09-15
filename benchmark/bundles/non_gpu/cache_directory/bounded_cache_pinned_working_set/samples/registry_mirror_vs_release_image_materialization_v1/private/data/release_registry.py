#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(131072), b""):
            value.update(block)
    return value.hexdigest()


def atomic_state(path, value):
    path = pathlib.Path(path)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(temp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--lease", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args()
    manifest = json.loads(pathlib.Path(args.manifest).read_text())
    held_layers = [
        (pathlib.Path(args.store) / "content" / "blobs" / "sha256" / item["sha256"]).open("rb")
        for item in manifest["layers"]
    ]
    lock = threading.Lock()
    state = {
        "pid": os.getpid(),
        "image": manifest["image"],
        "tag": manifest["tag"],
        "manifest_sha256": manifest["manifest_sha256"],
        "lease": args.lease,
        "offline_pulls": 0,
    }

    def healthy():
        lease_path = pathlib.Path(args.store) / "metadata" / "leases" / f"{args.lease}.json"
        if not lease_path.is_file():
            return False
        lease = json.loads(lease_path.read_text())
        expected = [item["sha256"] for item in manifest["layers"]]
        if lease.get("layer_digests") != expected or lease.get("holder_pid") != os.getpid():
            return False
        if lease.get("manifest_sha256") != manifest["manifest_sha256"]:
            return False
        for item in manifest["layers"]:
            path = pathlib.Path(args.store) / "content" / "blobs" / "sha256" / item["sha256"]
            if not path.is_file() or path.stat().st_size != item["size"] or digest(path) != item["sha256"]:
                return False
        return len(held_layers) == len(manifest["layers"])

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            return

        def send_json(self, status, payload):
            body = json.dumps(payload, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            ready = healthy()
            manifest_path = f"/v2/{manifest['image']}/manifests/{manifest['tag']}"
            if self.path == "/healthz":
                with lock:
                    payload = {**state, "ready": ready, "open_layers": len(held_layers)}
                    atomic_state(args.state_file, payload)
                self.send_json(200 if ready else 503, payload)
                return
            if self.path == manifest_path and ready:
                with lock:
                    state["offline_pulls"] += 1
                    payload = {**manifest, "offline_pulls": state["offline_pulls"]}
                    atomic_state(args.state_file, {**state, "ready": True, "open_layers": len(held_layers)})
                self.send_json(200, payload)
                return
            self.send_json(503 if not ready else 404, {"ready": ready})

    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    atomic_state(args.state_file, {**state, "ready": False, "open_layers": len(held_layers)})
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    server.serve_forever(poll_interval=0.1)
    server.server_close()
    for handle in held_layers:
        handle.close()


if __name__ == "__main__":
    main()
