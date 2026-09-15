#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def atomic_json(path, payload):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def now():
    return time.time()


class ControlHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        message = "%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), fmt % args)
        with self.server.log_lock:
            with open(self.server.log_path, "a", encoding="utf-8") as handle:
                handle.write(message)

    def send_json(self, code, payload, started):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        handler_ms = (time.perf_counter() - started) * 1000.0
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Handler-Ms", f"{handler_ms:.3f}")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        started = time.perf_counter()
        parsed = urllib.parse.urlparse(self.path)
        fixture = self.server.fixture
        if parsed.path == "/health":
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "pid": os.getpid(),
                "time": now(),
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/migration/lock":
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "lock_state": fixture["lock_state"],
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/schema/version":
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "schema_version": fixture["schema_version"],
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/schema/checksums":
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "checksums": fixture["schema_checksums"],
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/migration/window":
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "validation_window": fixture["validation_window"],
            }
            self.send_json(200, payload, started)
            return
        if parsed.path.startswith("/v1/migration/validation/"):
            plan_id = parsed.path.rsplit("/", 1)[-1]
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "plan_id": plan_id,
                "status": "ready",
                "dry_run_only": True,
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/basebackup/manifest":
            self.send_json(200, self.server.snapshot_manifest(), started)
            return
        self.send_json(404, {"ok": False, "error": "not_found", "path": parsed.path}, started)

    def do_POST(self):
        started = time.perf_counter()
        parsed = urllib.parse.urlparse(self.path)
        fixture = self.server.fixture
        body = self.read_body()
        if parsed.path == "/v1/migration/dry-run":
            try:
                request = json.loads(body.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                self.send_json(400, {"ok": False, "error": "bad_json"}, started)
                return
            basis = json.dumps(
                {
                    "service": fixture["service"],
                    "cluster": fixture["cluster"],
                    "revision": request.get("migration_revision"),
                    "schema_version": fixture["schema_version"],
                },
                sort_keys=True,
            ).encode("utf-8")
            plan_id = hashlib.sha256(basis).hexdigest()[:24]
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "plan_id": plan_id,
                "migration_revision": request.get("migration_revision"),
                "writes": False,
                "steps": [
                    "read current schema version",
                    "verify partition map checksum",
                    "render dry-run migration plan",
                    "prepare readiness receipt",
                ],
            }
            self.send_json(200, payload, started)
            return
        if parsed.path == "/v1/readiness/receipt":
            try:
                request = json.loads(body.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                self.send_json(400, {"ok": False, "error": "bad_json"}, started)
                return
            basis = json.dumps(
                {
                    "fixture": fixture,
                    "request": request,
                    "receipt_kind": "migration-readiness",
                },
                sort_keys=True,
            ).encode("utf-8")
            payload = {
                "ok": True,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
                "receipt_id": hashlib.sha256(basis).hexdigest()[:32],
                "signature": hashlib.sha256(b"receipt:" + basis).hexdigest(),
                "accepted": True,
            }
            self.send_json(200, payload, started)
            return
        if parsed.path.startswith("/v1/basebackup/segments/"):
            segment_id = parsed.path.rsplit("/", 1)[-1]
            expected = self.headers.get("X-Segment-Sha256", "")
            digest = hashlib.sha256(body).hexdigest()
            if expected and expected != digest:
                self.send_json(
                    422,
                    {"ok": False, "error": "checksum_mismatch", "segment_id": segment_id},
                    started,
                )
                return
            entry = self.server.commit_segment(segment_id, digest, len(body))
            self.send_json(200, {"ok": True, "accepted": entry}, started)
            return
        self.send_json(404, {"ok": False, "error": "not_found", "path": parsed.path}, started)


class ControlServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, fixture, state_dir):
        super().__init__(address, handler)
        self.fixture = fixture
        self.state_dir = pathlib.Path(state_dir)
        self.segment_dir = self.state_dir / "accepted_segments"
        self.segment_dir.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.state_dir / "backup_manifest.json"
        self.status_path = self.state_dir / "gateway_status.json"
        self.log_path = self.state_dir / "control_plane.log"
        self.log_lock = threading.Lock()
        self.manifest_lock = threading.Lock()
        self.started_at = now()
        if not self.manifest_path.exists():
            atomic_json(
                self.manifest_path,
                {
                    "schema": "pg-basebackup-manifest-v1",
                    "service": fixture["service"],
                    "cluster": fixture["cluster"],
                    "segments": [],
                    "committed_bytes": 0,
                    "updated_at": self.started_at,
                },
            )
        atomic_json(
            self.status_path,
            {
                "ok": True,
                "pid": os.getpid(),
                "started_at": self.started_at,
                "service": fixture["service"],
                "cluster": fixture["cluster"],
            },
        )

    def snapshot_manifest(self):
        try:
            return json.loads(self.manifest_path.read_text())
        except Exception:
            return {
                "schema": "pg-basebackup-manifest-v1",
                "service": self.fixture["service"],
                "cluster": self.fixture["cluster"],
                "segments": [],
                "committed_bytes": 0,
                "updated_at": now(),
            }

    def commit_segment(self, segment_id, digest, length):
        with self.manifest_lock:
            manifest = self.snapshot_manifest()
            target = self.segment_dir / f"{segment_id}.sha256"
            target.write_text(f"{digest}  {segment_id}\n", encoding="utf-8")
            offset = int(manifest.get("committed_bytes", 0))
            entry = {
                "segment_id": segment_id,
                "sha256": digest,
                "length": int(length),
                "offset": offset,
                "committed_at": now(),
            }
            manifest.setdefault("segments", []).append(entry)
            manifest["committed_bytes"] = offset + int(length)
            manifest["updated_at"] = now()
            atomic_json(self.manifest_path, manifest)
            return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()

    fixture = json.loads(pathlib.Path(args.fixture).read_text())
    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    server = ControlServer((args.host, args.port), ControlHandler, fixture, state_dir)

    def terminate(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
