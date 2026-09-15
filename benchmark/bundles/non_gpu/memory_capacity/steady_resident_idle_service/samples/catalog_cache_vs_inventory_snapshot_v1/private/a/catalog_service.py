#!/usr/bin/env python3
"""Serve catalog lookups from a preloaded anonymous search index."""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mmap
import os
from pathlib import Path
import signal
import time
from urllib.parse import parse_qs, urlparse

MIB = 1024 * 1024
RUNNING = True
SERVICE = None


def request_stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def atomic_json(path, payload):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def cgroup_dir():
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            return Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    raise RuntimeError("unified cgroup v2 membership not found")


def numeric(path):
    text = Path(path).read_text().strip()
    return None if text == "max" else int(text)


def process_rss_kib():
    for line in Path("/proc/self/status").read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


class CatalogState:
    def __init__(self, catalog_path, state_mib, guard_mib):
        raw = Path(catalog_path).read_bytes()
        payload = json.loads(raw)
        records = payload["records"]
        self.records = {record["sku"]: record for record in records}
        if not records or len(self.records) != len(records):
            raise ValueError("catalog records require unique SKUs")
        self.catalog_sha256 = hashlib.sha256(raw).hexdigest()
        self.canary_sku = payload["canary_sku"]
        if self.canary_sku not in self.records:
            raise ValueError("canary_sku is not present in catalog records")
        self.state_mib = state_mib
        self.state_bytes = state_mib * MIB
        self.virtual_product_count = int(payload["virtual_product_count"])
        self.started_at = time.time()
        self.request_count = 0

        cg = cgroup_dir()
        memory_max = numeric(cg / "memory.max")
        memory_current = numeric(cg / "memory.current")
        if memory_max is None or memory_current is None:
            raise RuntimeError("finite cgroup memory controls are required")
        if memory_current + self.state_bytes + guard_mib * MIB > memory_max:
            raise RuntimeError(
                f"insufficient memory for catalog index: current={memory_current} "
                f"state={self.state_bytes} max={memory_max}"
            )
        self.memory_max = memory_max
        self.index = mmap.mmap(-1, self.state_bytes, access=mmap.ACCESS_WRITE)
        chunk_bytes = 4 * MIB
        seed = int(payload["index_seed"])
        for chunk_index, offset in enumerate(range(0, self.state_bytes, chunk_bytes)):
            value = (seed + chunk_index * 29 + chunk_index // 17) % 256
            length = min(chunk_bytes, self.state_bytes - offset)
            self.index[offset : offset + length] = bytes((value,)) * length

        digest = hashlib.sha256()
        for sample in range(4096):
            offset = sample * (self.state_bytes - 1) // 4095
            digest.update(bytes((self.index[offset],)))
        self.index_sample_sha256 = digest.hexdigest()

    def lookup(self, sku):
        record = self.records.get(sku)
        if record is None:
            return None
        slot = int(record["index_slot"])
        offset = slot * (self.state_bytes - 1) // max(1, len(self.records) - 1)
        return {
            **record,
            "index_byte": self.index[offset],
            "index_sample_sha256": self.index_sample_sha256,
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def send_json(self, status, payload):
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        SERVICE.request_count += 1
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self.send_json(
                200,
                {
                    "status": "ok",
                    "service": "regional-catalog-index",
                    "pid": os.getpid(),
                    "record_count": len(SERVICE.records),
                    "virtual_product_count": SERVICE.virtual_product_count,
                    "state_mib": SERVICE.state_mib,
                    "catalog_sha256": SERVICE.catalog_sha256,
                    "index_sample_sha256": SERVICE.index_sample_sha256,
                    "request_count": SERVICE.request_count,
                },
            )
            return
        if parsed.path == "/catalog/item":
            sku = parse_qs(parsed.query).get("sku", [""])[0]
            record = SERVICE.lookup(sku)
            if record is None:
                self.send_json(404, {"status": "not_found", "sku": sku})
            else:
                self.send_json(200, {"status": "ok", "item": record})
            return
        self.send_json(404, {"status": "not_found"})


def main():
    global SERVICE
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-mib", type=int, required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--guard-mib", type=int, default=128)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    SERVICE = CatalogState(args.catalog, args.state_mib, args.guard_mib)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.timeout = 0.25
    atomic_json(
        run_dir / "ready.json",
        {
            "pid": os.getpid(),
            "port": args.port,
            "state_mib": args.state_mib,
            "state_bytes": SERVICE.state_bytes,
            "record_count": len(SERVICE.records),
            "virtual_product_count": SERVICE.virtual_product_count,
            "canary_sku": SERVICE.canary_sku,
            "catalog_sha256": SERVICE.catalog_sha256,
            "index_sample_sha256": SERVICE.index_sample_sha256,
            "memory_max_bytes": SERVICE.memory_max,
            "rss_kib": process_rss_kib(),
            "ready_at_unix": time.time(),
        },
    )
    while RUNNING:
        server.handle_request()
    server.server_close()
    atomic_json(
        run_dir / "stopped.json",
        {
            "pid": os.getpid(),
            "request_count": SERVICE.request_count,
            "mode": "graceful_sigterm",
            "stopped_at_unix": time.time(),
        },
    )
    SERVICE.index.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
