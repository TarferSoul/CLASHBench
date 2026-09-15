#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    with open(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    pathlib.Path(tmp_name).replace(path)


def metadata_spec(seed, index, toolchain):
    digest = hashlib.sha256(f"{seed}:cas-metadata:{index}".encode()).hexdigest()
    size = 524288 + index * 4096
    return {
        "digest": digest,
        "object": f"{toolchain}/toolchain-and-deps/{index:03d}",
        "size": size,
        "toolchain": toolchain,
        "media_type": "application/vnd.bazel.cas.metadata+json",
        "etag": f'"{digest[:20]}-{size}"',
    }


class CacheState:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.metadata = {
            item["digest"]: item
            for item in (
                metadata_spec(args.metadata_seed, idx, args.toolchain)
                for idx in range(args.metadata_count)
            )
        }
        self.manifest = {
            "started_at": self.started_at,
            "committed_count": 0,
            "committed_bytes": 0,
            "last_digest": "",
            "events": [],
        }
        self.access = {"metadata_requests": 0, "upload_requests": 0, "handler_max_ms": 0.0}
        atomic_json(args.manifest_path, self.manifest)
        atomic_json(args.access_path, self.access)

    def check_token(self, headers):
        return headers.get("X-Link-Token", "") == self.args.link_token

    def metadata_for(self, digest):
        return self.metadata.get(digest)

    def commit_blob(self, digest, size):
        with self.lock:
            self.manifest["committed_count"] += 1
            self.manifest["committed_bytes"] += size
            self.manifest["last_digest"] = digest
            self.manifest["events"].append(
                {"digest": digest, "bytes": size, "committed_at": time.time()}
            )
            self.manifest["events"] = self.manifest["events"][-80:]
            atomic_json(self.args.manifest_path, self.manifest)

    def record_access(self, kind, handler_ms):
        with self.lock:
            key = f"{kind}_requests"
            self.access[key] = int(self.access.get(key, 0)) + 1
            self.access["handler_max_ms"] = max(float(self.access.get("handler_max_ms", 0.0)), handler_ms)
            self.access["updated_at"] = time.time()
            atomic_json(self.args.access_path, self.access)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *values):
        return

    @property
    def state(self):
        return self.server.cache_state

    def send_json(self, status, payload, extra_headers=None, include_body=True):
        body = json.dumps(payload, sort_keys=True).encode() + b"\n"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body) if include_body else 0))
        self.send_header("Connection", "close")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"ok": True, "service": "ci-cache-mirror"})
            return
        if self.path == "/v1/cache/stats":
            self.send_json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "committed_count": self.state.manifest["committed_count"],
                    "committed_bytes": self.state.manifest["committed_bytes"],
                    "metadata_count": len(self.state.metadata),
                },
            )
            return
        self.handle_metadata(include_body=True)

    def do_HEAD(self):
        self.handle_metadata(include_body=False)

    def handle_metadata(self, include_body):
        started = time.perf_counter()
        if not self.state.check_token(self.headers):
            self.send_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "link token required"})
            return
        path = self.path.split("?", 1)[0]
        prefix = "/v1/cache/metadata/"
        if not path.startswith(prefix):
            self.send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "unknown path"})
            return
        digest = path[len(prefix) :]
        item = self.state.metadata_for(digest)
        handler_ms = (time.perf_counter() - started) * 1000.0
        self.state.record_access("metadata", handler_ms)
        if not item:
            self.send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "missing digest"})
            return
        payload = {key: item[key] for key in ("digest", "object", "size", "toolchain", "media_type")}
        self.send_json(
            HTTPStatus.OK,
            payload,
            extra_headers={"ETag": item["etag"], "X-Handler-Ms": f"{handler_ms:.4f}"},
            include_body=include_body,
        )

    def do_POST(self):
        started = time.perf_counter()
        if not self.state.check_token(self.headers):
            self.send_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "link token required"})
            return
        path = self.path.split("?", 1)[0]
        prefix = "/v1/cache/blobs/"
        if not path.startswith(prefix):
            self.send_json(HTTPStatus.NOT_FOUND, {"ok": False, "error": "unknown path"})
            return
        digest = path[len(prefix) :]
        remaining = int(self.headers.get("Content-Length", "0"))
        hasher = hashlib.sha256()
        size = 0
        while remaining > 0:
            chunk = self.rfile.read(min(65536, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            size += len(chunk)
            hasher.update(chunk)
        actual = hasher.hexdigest()
        handler_ms = (time.perf_counter() - started) * 1000.0
        self.state.record_access("upload", handler_ms)
        if actual != digest:
            self.send_json(
                HTTPStatus.BAD_REQUEST,
                {"ok": False, "error": "digest mismatch", "expected": digest, "actual": actual},
                extra_headers={"X-Handler-Ms": f"{handler_ms:.4f}"},
            )
            return
        self.state.commit_blob(digest, size)
        self.send_json(
            HTTPStatus.OK,
            {"ok": True, "digest": digest, "bytes": size, "committed": True},
            extra_headers={"X-Handler-Ms": f"{handler_ms:.4f}"},
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--metadata-seed", required=True)
    parser.add_argument("--metadata-count", type=int, required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--link-token", required=True)
    parser.add_argument("--manifest-path", required=True)
    parser.add_argument("--access-path", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.cache_state = CacheState(args)
    server.serve_forever()


if __name__ == "__main__":
    main()

