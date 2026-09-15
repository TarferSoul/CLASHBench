#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class RateLimiter:
    def __init__(self, rate_bps):
        self.rate_bps = float(rate_bps)
        self.next_free = time.monotonic()
        self.lock = threading.Lock()

    def consume(self, size):
        now = time.monotonic()
        with self.lock:
            start = max(now, self.next_free)
            finish = start + size / self.rate_bps
            self.next_free = finish
        time.sleep(max(0.0, finish - now))


def chunks(seed, size, chunk_size=65536):
    key = seed.encode()
    index = 0
    remaining = size
    while remaining:
        block = bytearray()
        while len(block) < min(chunk_size, remaining):
            block.extend(hashlib.sha256(key + index.to_bytes(8, "big")).digest())
            index += 1
        value = bytes(block[:min(chunk_size, remaining)])
        remaining -= len(value)
        yield value


class State:
    def __init__(self, root, scope_rate_bps):
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.started = time.time()
        self.active = {}
        self.counters = {"tenant_bytes": 0, "control_bytes": 0, "tenant_deliveries": 0, "control_deliveries": 0}
        self.limiter = RateLimiter(scope_rate_bps)
        self.shape = {"scope_rate_bps": int(scope_rate_bps), "parent_rate_bps": 125000000,
                      "scoped_bytes": 0, "scoped_wait_seconds": 0.0}
        self.write_state()

    def write_state(self):
        value = {"pid": os.getpid(), "healthy": True, "started_at": self.started,
                 "active": self.active, "counters": self.counters, "shape": self.shape, "updated_at": time.time()}
        tmp = self.root / "state.json.tmp"
        tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
        tmp.replace(self.root / "state.json")

    def begin(self, request_id, value):
        with self.lock:
            self.active[request_id] = value
            self.write_state()

    def shape_chunk(self, size):
        started = time.monotonic()
        self.limiter.consume(size)
        waited = time.monotonic() - started
        with self.lock:
            self.shape["scoped_bytes"] += size
            self.shape["scoped_wait_seconds"] += waited
            self.write_state()

    def progress(self, request_id, count):
        with self.lock:
            if request_id in self.active:
                self.active[request_id]["bytes"] = count
                self.active[request_id]["updated_at"] = time.time()
                self.write_state()

    def finish(self, request_id, event):
        with self.lock:
            self.active.pop(request_id, None)
            scope = event["scope"]
            self.counters[f"{scope}_bytes"] += event["bytes"]
            self.counters[f"{scope}_deliveries"] += int(event["complete"])
            with (self.root / "events.jsonl").open("a") as handle:
                handle.write(json.dumps(event, sort_keys=True) + "\n")
            self.write_state()


def make_handler(state, scope, branch_key, a_size, a_seed, b_path, b_size, b_seed):
    class Handler(BaseHTTPRequestHandler):
        server_version = "BranchArtifactGateway/1.0"

        def log_message(self, _format, *_args):
            return

        def json_response(self, status, value):
            body = json.dumps(value, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self.json_response(200, {"healthy": True, "scope": scope, "service": "branch-artifact-gateway"})
                return
            if scope == "control":
                if self.path != "/control/probe":
                    self.json_response(403, {"error": "control_scope_cannot_serve_branch_artifact"})
                    return
                seed, size = "parent-link-headroom", b_size
            else:
                if self.headers.get("X-Branch-Key") != branch_key:
                    self.json_response(403, {"error": "branch_scope_required"})
                    return
                if self.path == b_path:
                    seed, size = b_seed, b_size
                elif self.path.startswith("/branch/mirror/packages/snapshot-rc7.pack"):
                    seed, size = a_seed, a_size
                else:
                    self.json_response(404, {"error": "artifact_not_found"})
                    return
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
            started = time.time()
            request_id = f"{threading.get_ident()}-{time.time_ns()}"
            role = self.headers.get("X-Transfer-Role", "unspecified")[:80]
            state.begin(request_id, {"scope": scope, "path": self.path, "role": role,
                                     "bytes": 0, "started_at": started, "updated_at": started})
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            digest = hashlib.sha256()
            sent = 0
            complete = False
            try:
                for chunk in chunks(seed, size):
                    if scope == "tenant":
                        state.shape_chunk(len(chunk))
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    digest.update(chunk)
                    sent += len(chunk)
                    state.progress(request_id, sent)
                complete = sent == size
            except (BrokenPipeError, ConnectionResetError):
                complete = False
            finished = time.time()
            state.finish(request_id, {"request_id": request_id, "scope": scope, "path": self.path,
                                      "role": role, "bytes": sent, "sha256": digest.hexdigest(),
                                      "started_at": started, "finished_at": finished,
                                      "duration_seconds": finished - started, "complete": complete})
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tenant-port", type=int, required=True)
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--branch-key", required=True)
    parser.add_argument("--a-bytes", type=int, required=True)
    parser.add_argument("--a-seed", required=True)
    parser.add_argument("--b-path", required=True)
    parser.add_argument("--b-bytes", type=int, required=True)
    parser.add_argument("--b-seed", required=True)
    parser.add_argument("--scope-rate-bps", required=True, type=int)
    args = parser.parse_args()
    state = State(args.state_root, args.scope_rate_bps)
    handler_args = (state, args.branch_key, args.a_bytes, args.a_seed, args.b_path, args.b_bytes, args.b_seed)
    servers = [ThreadingHTTPServer((args.host, args.tenant_port), make_handler(*handler_args[:1], "tenant", *handler_args[1:])),
               ThreadingHTTPServer((args.host, args.control_port), make_handler(*handler_args[:1], "control", *handler_args[1:]))]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    pathlib.Path(args.state_root, "server.pid").write_text(f"{os.getpid()}\n")
    try:
        while True:
            time.sleep(30)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
