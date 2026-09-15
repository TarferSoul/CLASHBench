#!/usr/bin/env python3
"""Warm a repository symbol index and serve deterministic canary queries."""

import argparse
import ast
from http.server import BaseHTTPRequestHandler, HTTPServer
import hashlib
import json
import os
from pathlib import Path
import signal
import time
from urllib.parse import parse_qs, urlparse

MIB = 1024 * 1024
RUNNING = True


def request_stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def atomic_json(path, payload):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
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


def module_source(module):
    imports = "\n".join(f"import {name}" for name in module["imports"])
    body = [imports, ""]
    for idx, symbol in enumerate(module["symbols"]):
        if symbol[:1].isupper():
            body.append(f"class {symbol}:")
            body.append(f"    marker = {idx}")
            body.append("    def fingerprint(self):")
            body.append(f"        return '{module['path']}::{symbol}'")
            body.append("")
        else:
            body.append(f"def {symbol}(value, scale={idx + 1}):")
            body.append(f"    token = '{module['path']}::{symbol}'")
            body.append("    return (hash(token) ^ int(value)) % (scale + 997)")
            body.append("")
    return "\n".join(body)


def build_index(fixture):
    records = []
    for module in fixture["modules"]:
        source = module_source(module)
        tree = ast.parse(source, filename=module["path"])
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
                source_key = f"{module['path']}:{node.name}:{getattr(node, 'lineno', 0)}"
                records.append(
                    {
                        "module": module["path"],
                        "symbol": node.name,
                        "kind": "class" if isinstance(node, ast.ClassDef) else "function",
                        "line": getattr(node, "lineno", 0),
                        "digest": hashlib.sha256(source_key.encode()).hexdigest(),
                    }
                )
    index = {record["symbol"]: record for record in records}
    canonical = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return index, records, hashlib.sha256(canonical).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-mib", type=int, required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--guard-mib", type=int, default=96)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    fixture_bytes = Path(args.fixture).read_bytes()
    fixture = json.loads(fixture_bytes)
    index, records, index_digest = build_index(fixture)
    canary = fixture["canary_symbol"]
    if canary not in index:
        raise SystemExit("configured canary symbol is absent from index")

    cg = cgroup_dir()
    memory_max = numeric(cg / "memory.max")
    memory_current = numeric(cg / "memory.current")
    if memory_max is None:
        raise SystemExit("finite cgroup memory.max is required")
    cache_bytes = args.cache_mib * MIB
    if memory_current + cache_bytes + args.guard_mib * MIB > memory_max:
        raise SystemExit(
            f"insufficient cgroup headroom for warm index cache: current={memory_current} cache={cache_bytes} max={memory_max}"
        )

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    started = time.monotonic()
    cache = bytearray(cache_bytes)
    chunk_bytes = 4 * MIB
    record_count = max(1, len(records))
    for chunk_index, offset in enumerate(range(0, cache_bytes, chunk_bytes)):
        record = records[chunk_index % record_count]
        digest_byte = int(record["digest"][0:2], 16)
        length = min(chunk_bytes, cache_bytes - offset)
        cache[offset : offset + length] = bytes((digest_byte,)) * length
    warm_probe = sum(cache[offset] for offset in range(0, cache_bytes, chunk_bytes))
    fixture_digest = hashlib.sha256(fixture_bytes).hexdigest()

    class Handler(BaseHTTPRequestHandler):
        def send_json(self, status, payload):
            body = (json.dumps(payload, sort_keys=True) + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self.send_json(
                    200,
                    {
                        "status": "ok",
                        "warm": True,
                        "index_digest": index_digest,
                        "symbol_count": len(index),
                        "cache_mib": args.cache_mib,
                    },
                )
                return
            if parsed.path == "/lookup":
                symbol = parse_qs(parsed.query).get("symbol", [""])[0]
                record = index.get(symbol)
                if record is None:
                    self.send_json(404, {"status": "missing", "symbol": symbol})
                    return
                self.send_json(200, {"status": "ok", "symbol": symbol, "record": record, "index_digest": index_digest})
                return
            self.send_json(404, {"status": "missing"})

        def log_message(self, _format, *_args):
            return

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.timeout = 0.2
    atomic_json(
        run_dir / "ready.json",
        {
            "pid": os.getpid(),
            "port": args.port,
            "cache_mib": args.cache_mib,
            "cache_bytes": cache_bytes,
            "symbol_count": len(index),
            "fixture_digest": fixture_digest,
            "index_digest": index_digest,
            "canary_symbol": canary,
            "canary_digest": index[canary]["digest"],
            "warm_probe": warm_probe,
            "rss_kib": process_rss_kib(),
            "memory_max_bytes": memory_max,
            "warmup_seconds": round(time.monotonic() - started, 6),
            "status": "warm",
        },
    )
    requests = 0
    while RUNNING:
        server.handle_request()
        requests += 1
    server.server_close()
    atomic_json(
        run_dir / "stopped.json",
        {
            "pid": os.getpid(),
            "mode": "graceful_sigterm",
            "requests": requests,
            "index_digest": index_digest,
        },
    )
    del cache
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

