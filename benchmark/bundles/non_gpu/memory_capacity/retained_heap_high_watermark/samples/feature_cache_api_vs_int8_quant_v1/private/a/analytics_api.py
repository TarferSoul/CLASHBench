#!/usr/bin/env python3
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlparse


MIB = 1024 * 1024
PAGE = 4096
STATE = {
    "warmed": False,
    "generation": "",
    "buffers": [],
    "partitions": [],
    "row_count": 0,
    "cache_bytes": 0,
    "cohort_checksum": "",
    "warm_elapsed_ms": 0.0,
    "started_at": time.time(),
}
LOCK = threading.Lock()


def cgroup_path(name):
    candidates = [Path("/sys/fs/cgroup") / name]
    try:
        for line in Path("/proc/self/cgroup").read_text().splitlines():
            parts = line.split(":", 2)
            if len(parts) == 3 and parts[1] == "":
                rel = parts[2].lstrip("/")
                candidates.append(Path("/sys/fs/cgroup") / rel / name)
    except OSError:
        pass
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


def cgroup_value(name):
    path = cgroup_path(name)
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def cgroup_int(name):
    raw = cgroup_value(name)
    if raw in {"", "max"}:
        return None
    return int(raw)


def target_mib():
    explicit = os.environ.get("FEATURE_CACHE_TARGET_MIB")
    if explicit:
        return int(explicit)
    limit = cgroup_int("memory.max")
    if not limit:
        return 2048
    pct = float(os.environ.get("FEATURE_CACHE_TARGET_PCT", "72"))
    return max(512, int((limit // MIB) * pct / 100.0))


def chunk_mib():
    return max(1, int(os.environ.get("FEATURE_CACHE_CHUNK_MIB", "32")))


def touch(size, seed):
    buf = bytearray(size)
    value = seed & 255
    for index in range(0, size, PAGE):
        buf[index] = value
        value = (value + 29) & 255
    return buf


def build_cache():
    with LOCK:
        if STATE["warmed"]:
            return metrics()
        start = time.time()
        remaining = target_mib()
        chunk = chunk_mib()
        buffers = []
        partitions = []
        digest = hashlib.sha256()
        partition_index = 0
        row_count = 0
        while remaining > 0:
            now = min(chunk, remaining)
            buf = touch(now * MIB, partition_index * 53 + 11)
            buffers.append(buf)
            sample = bytes(buf[offset] for offset in range(0, min(len(buf), PAGE * 256), PAGE))
            digest.update(sample)
            rows = now * 2048
            row_count += rows
            partitions.append(
                {
                    "partition": f"features_{partition_index:03d}",
                    "decoded_bytes": len(buf),
                    "rows": rows,
                    "dictionary_terms": 8192 + partition_index * 13,
                    "time_window": f"2026-W{(partition_index % 26) + 1:02d}",
                }
            )
            partition_index += 1
            remaining -= now
        STATE.update(
            warmed=True,
            generation=f"cache-{int(start)}-{len(buffers)}",
            buffers=buffers,
            partitions=partitions,
            row_count=row_count,
            cache_bytes=sum(len(item) for item in buffers),
            cohort_checksum=digest.hexdigest(),
            warm_elapsed_ms=round((time.time() - start) * 1000.0, 3),
        )
        return metrics()


def query_cohort(name):
    started = time.time()
    with LOCK:
        if not STATE["warmed"]:
            raise RuntimeError("cache is not warm")
        digest = hashlib.sha256()
        for index, buf in enumerate(STATE["buffers"]):
            offset = ((index * 104729) + len(name) * 4099) % max(1, len(buf) - 4096)
            digest.update(buf[offset : offset + 64])
        payload = {
            "cohort": name,
            "generation": STATE["generation"],
            "row_count": STATE["row_count"],
            "partition_count": len(STATE["partitions"]),
            "checksum": hashlib.sha256((STATE["cohort_checksum"] + digest.hexdigest()).encode()).hexdigest(),
            "elapsed_ms": round((time.time() - started) * 1000.0, 3),
        }
        return payload


def metrics():
    return {
        "ok": STATE["warmed"],
        "pid": os.getpid(),
        "started_at": STATE["started_at"],
        "generation": STATE["generation"],
        "partition_count": len(STATE["partitions"]),
        "row_count": STATE["row_count"],
        "cache_bytes": STATE["cache_bytes"],
        "cohort_checksum": STATE["cohort_checksum"],
        "warm_elapsed_ms": STATE["warm_elapsed_ms"],
        "cgroup_memory_max": cgroup_value("memory.max"),
        "cgroup_memory_current": cgroup_value("memory.current"),
        "cgroup_memory_peak": cgroup_value("memory.peak"),
        "cgroup_memory_high": cgroup_value("memory.high"),
        "cgroup_memory_swap_max": cgroup_value("memory.swap.max"),
        "cgroup_memory_swap_current": cgroup_value("memory.swap.current"),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "FeatureCacheAPI/1.0"

    def log_message(self, fmt, *args):
        return

    def write_json(self, code, payload):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/health":
                self.write_json(200 if STATE["warmed"] else 503, {"ok": STATE["warmed"], "pid": os.getpid()})
            elif parsed.path == "/warm_feature_cache":
                self.write_json(200, build_cache())
            elif parsed.path == "/metrics":
                self.write_json(200, metrics())
            elif parsed.path == "/cohort":
                params = parse_qs(parsed.query)
                name = params.get("name", ["ranker_canary"])[0]
                self.write_json(200, query_cohort(name))
            else:
                self.write_json(404, {"error": "not_found"})
        except Exception as exc:
            self.write_json(500, {"error": type(exc).__name__, "message": str(exc)})


def main():
    port = int(os.environ.get("FEATURE_CACHE_PORT", "18171"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
