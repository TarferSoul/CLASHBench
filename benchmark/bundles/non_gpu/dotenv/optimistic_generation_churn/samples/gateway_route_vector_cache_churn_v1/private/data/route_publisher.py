#!/usr/bin/env python3
"""Live gateway discovery publisher that updates a dotenv route table."""

from __future__ import annotations

import argparse
import http.server
import json
import pathlib
import random
import socketserver
import sys
import threading
import time
import urllib.request

import env_update


class HealthServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def handler_for(name: str):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_response(404)
                self.end_headers()
                return
            body = json.dumps({"service": name, "ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            return

    return Handler


def start_health_endpoints(backends: list[dict]) -> list[HealthServer]:
    servers = []
    for item in backends:
        server = HealthServer((item["host"], int(item["port"])), handler_for(item["name"]))
        thread = threading.Thread(target=server.serve_forever, name=f"health-{item['name']}", daemon=True)
        thread.start()
        servers.append(server)
    return servers


def probe(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=0.15) as response:
            return response.status == 200
    except Exception:
        return False


def build_route(backends: list[dict], cycle: int) -> dict:
    entries = []
    active = 0
    for idx, backend in enumerate(backends):
        ok = probe(f"http://{backend['host']}:{backend['port']}/health")
        draining = (cycle + idx) % 7 == 0
        state = "up" if ok and not draining else "draining"
        weight = int(backend["base_weight"]) + ((cycle + idx * 3) % 9)
        if state == "up":
            active += 1
        entries.append(
            "%s@%s:%s:w=%s:s=%s"
            % (backend["name"], backend["host"], backend["port"], weight, state)
        )
    observed = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    patch = {
        "API_BACKEND_SET": ";".join(entries),
        "ACTIVE_BACKEND_COUNT": str(active),
        "DISCOVERY_OBSERVED_AT": observed,
    }
    patch["ROUTING_TABLE_SHA"] = env_update.route_sha(patch)
    return patch


def write_state(path: pathlib.Path, payload: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--min-interval", type=float, default=0.15)
    parser.add_argument("--max-interval", type=float, default=0.22)
    args = parser.parse_args()

    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    state_path = state_dir / "discovery_state.json"
    backends = json.loads(pathlib.Path(args.catalog).read_text(encoding="utf-8"))["backends"]
    servers = start_health_endpoints(backends)
    updates = 0
    stale = 0
    random.seed(4319)
    try:
        while True:
            values, counts = env_update.parse_env(args.file)
            env_update.validate_values(values, counts)
            expected = int(values[env_update.GENERATION_KEY])
            patch = build_route(backends, updates)
            try:
                result = env_update.commit_update(args.file, expected, patch, args.schema)
                updates += 1
                write_state(
                    state_path,
                    {
                        "pid": pathlib.Path("/proc/self").stat().st_ino,
                        "process_id": os_getpid(),
                        "updates": updates,
                        "stale_retries": stale,
                        "generation": result["new_generation"],
                        "route": patch,
                        "updated_at": time.time(),
                    },
                )
            except env_update.StaleGeneration:
                stale += 1
            time.sleep(random.uniform(args.min_interval, args.max_interval))
    finally:
        for server in servers:
            server.shutdown()
    return 0


def os_getpid() -> int:
    import os

    return os.getpid()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
    except Exception as exc:
        print(f"DISCOVERY_PUBLISHER_ERROR={type(exc).__name__}:{exc}", file=sys.stderr)
        raise SystemExit(2)
