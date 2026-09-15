#!/usr/bin/env python3
import argparse
import hashlib
import http.server
import json
import multiprocessing as mp
import os
import pathlib
import queue
import signal
import socketserver
import threading
import time
import urllib.parse


MIB = 1024 * 1024
PAGE = 4096
CANARY_TEXT = "support ticket classifier canary auth timeout retrieval sdk drift"


def start_ticks(pid: int) -> int:
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])


def atomic_json(path: pathlib.Path, payload) -> None:
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def allocate_resident(mib: int, seed: int):
    chunks = []
    remaining = mib
    while remaining > 0:
        size_mib = min(32, remaining)
        block = bytearray(size_mib * MIB)
        for offset in range(0, len(block), PAGE):
            block[offset] = (seed + offset // PAGE) & 0xFF
        chunks.append(block)
        remaining -= size_mib
    return chunks


def touch_resident(chunks, seed: int) -> int:
    total = 0
    for index, block in enumerate(chunks):
        stride = PAGE * 29
        for offset in range((seed + index * 97) % PAGE, len(block), stride):
            total = (total + block[offset]) & 0xFFFFFFFF
            block[offset] = (block[offset] + 1) & 0xFF
    return total


def candidate_rows(worker: int):
    components = ["auth", "retrieval", "billing", "workflow", "sdk", "storage", "search", "routing"]
    rows = []
    for index in range(64):
        component = components[(worker + index * 3) % len(components)]
        rows.append(
            {
                "candidate_id": f"CAND-{worker:02d}-{index:04d}",
                "component": component,
                "summary": f"{component} support escalation candidate {index} for worker shard {worker}",
            }
        )
    return rows


def model_vector_digest(worker: int, text: str, rows) -> str:
    digest = hashlib.sha256()
    digest.update(f"minilm-routing-v1 worker={worker}".encode("utf-8"))
    digest.update(text.encode("utf-8"))
    for row in rows:
        digest.update(row["candidate_id"].encode("utf-8"))
        digest.update(row["component"].encode("utf-8"))
    return digest.hexdigest()


def worker_main(worker: int, resident_mib: int, state_root: str, request_queue, response_queue):
    root = pathlib.Path(state_root)
    status_path = root / "workers" / f"worker-{worker}.json"
    rows = candidate_rows(worker)
    resident = allocate_resident(resident_mib, worker + 73)
    served = 0
    digest = model_vector_digest(worker, CANARY_TEXT, rows)
    pid = os.getpid()
    ticks = start_ticks(pid)

    def write_status(phase: str):
        atomic_json(
            status_path,
            {
                "pid": pid,
                "worker": worker,
                "start_ticks": ticks,
                "pgid": os.getpgid(pid),
                "phase": phase,
                "heartbeat": time.time(),
                "served_batches": served,
                "resident_mib": resident_mib,
                "candidate_rows": len(rows),
                "canary_digest": digest,
            },
        )

    write_status("ready")
    last_heartbeat = 0.0
    while True:
        now = time.time()
        if now - last_heartbeat > 0.5:
            touch_resident(resident, worker)
            write_status("ready")
            last_heartbeat = now
        try:
            item = request_queue.get(timeout=0.2)
        except queue.Empty:
            continue
        if item.get("op") == "shutdown":
            write_status("stopping")
            return
        if item.get("op") in {"canary", "embed"}:
            touch_resident(resident, worker + served)
            served += 1
            write_status("ready")
            response_queue.put(
                {
                    "request_id": item.get("request_id"),
                    "worker": worker,
                    "pid": pid,
                    "served_batches": served,
                    "digest": digest,
                    "rows": len(rows),
                }
            )


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class Service:
    def __init__(self, args):
        self.args = args
        self.state_root = pathlib.Path(args.state_root)
        self.worker_dir = self.state_root / "workers"
        self.response_queue = mp.Queue()
        self.request_queues = []
        self.processes = []
        self.sequence = 0
        self.stop = threading.Event()
        self.supervisor_cache = []
        self.httpd = None

    def start_workers(self):
        self.worker_dir.mkdir(parents=True, exist_ok=True)
        for worker in range(self.args.workers):
            request_queue = mp.Queue()
            proc = mp.Process(
                target=worker_main,
                args=(worker, self.args.worker_resident_mib, str(self.state_root), request_queue, self.response_queue),
            )
            proc.start()
            self.request_queues.append(request_queue)
            self.processes.append(proc)
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            ready = 0
            for worker, proc in enumerate(self.processes):
                status_path = self.worker_dir / f"worker-{worker}.json"
                if not proc.is_alive():
                    raise RuntimeError(f"worker {worker} exited during warmup")
                if status_path.exists():
                    try:
                        status = json.loads(status_path.read_text())
                    except json.JSONDecodeError:
                        continue
                    if status.get("phase") == "ready" and status.get("pid") == proc.pid:
                        ready += 1
            if ready == self.args.workers:
                return
            time.sleep(0.1)
        raise RuntimeError("workers did not reach ready state")

    def write_service_json(self):
        payload = {
            "schema": "support-ticket-embedding-service-v1",
            "pid": os.getpid(),
            "start_ticks": start_ticks(os.getpid()),
            "pgid": os.getpgid(os.getpid()),
            "host": self.args.host,
            "port": self.args.port,
            "worker_count": self.args.workers,
            "worker_pids": [proc.pid for proc in self.processes],
            "worker_start_ticks": [start_ticks(proc.pid) for proc in self.processes],
            "restarts": 0,
            "worker_resident_mib": self.args.worker_resident_mib,
            "supervisor_resident_mib": self.args.supervisor_resident_mib,
            "created_at": time.time(),
        }
        atomic_json(self.state_root / "service.json", payload)

    def run_canary(self):
        self.sequence += 1
        request_id = f"canary-{self.sequence}"
        started = time.time()
        for request_queue in self.request_queues:
            request_queue.put({"op": "canary", "request_id": request_id, "text": CANARY_TEXT})
        replies = []
        deadline = time.monotonic() + 8
        while len(replies) < self.args.workers and time.monotonic() < deadline:
            try:
                item = self.response_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            if item.get("request_id") == request_id:
                replies.append(item)
        ok = len(replies) == self.args.workers
        digest = hashlib.sha256()
        for item in sorted(replies, key=lambda row: row["worker"]):
            digest.update(item["digest"].encode("utf-8"))
        checksum = digest.hexdigest()
        touch_resident(self.supervisor_cache, self.sequence)
        payload = {
            "schema": "support-ticket-embedding-health-v1",
            "ok": ok,
            "generation": self.sequence,
            "canary_count": self.sequence,
            "worker_count": len(replies),
            "expected_workers": self.args.workers,
            "checksum": checksum,
            "latency_ms": round((time.time() - started) * 1000, 3),
            "timestamp": time.time(),
        }
        atomic_json(self.state_root / "health.json", payload)
        return payload

    def fresh_health(self):
        try:
            health = json.loads((self.state_root / "health.json").read_text())
        except Exception:
            health = {"ok": False, "reason": "missing_health"}
        stale = []
        for worker in range(self.args.workers):
            try:
                status = json.loads((self.worker_dir / f"worker-{worker}.json").read_text())
            except Exception:
                stale.append(worker)
                continue
            if time.time() - float(status.get("heartbeat", 0.0)) > 5.0:
                stale.append(worker)
        health["stale_workers"] = stale
        health["ok"] = bool(health.get("ok")) and not stale
        return health

    def make_handler(self):
        service = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, fmt, *args):
                return

            def send_json(self, payload, status=200):
                encoded = json.dumps(payload, sort_keys=True).encode("utf-8")
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path == "/health":
                    self.send_json(service.fresh_health())
                elif parsed.path == "/canary":
                    self.send_json(service.run_canary())
                else:
                    self.send_json({"ok": False, "error": "unknown path"}, status=404)

            def do_POST(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path != "/embed":
                    self.send_json({"ok": False, "error": "unknown path"}, status=404)
                    return
                length = int(self.headers.get("content-length", "0") or "0")
                body = self.rfile.read(length)
                try:
                    payload = json.loads(body.decode("utf-8")) if body else {}
                except json.JSONDecodeError:
                    self.send_json({"ok": False, "error": "invalid json"}, status=400)
                    return
                health = service.run_canary()
                self.send_json({"ok": health["ok"], "texts": len(payload.get("texts", [])), "checksum": health["checksum"]})

        return Handler

    def serve(self):
        self.start_workers()
        self.write_service_json()
        self.supervisor_cache = allocate_resident(self.args.supervisor_resident_mib, 19)
        self.run_canary()
        self.httpd = ThreadingHTTPServer((self.args.host, self.args.port), self.make_handler())
        server_thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        server_thread.start()
        while not self.stop.is_set():
            self.run_canary()
            self.stop.wait(2.0)
        self.httpd.shutdown()
        for request_queue in self.request_queues:
            request_queue.put({"op": "shutdown"})
        for proc in self.processes:
            proc.join(timeout=5)
        for proc in self.processes:
            if proc.is_alive():
                proc.terminate()
        for proc in self.processes:
            proc.join(timeout=3)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--worker-resident-mib", type=int, required=True)
    parser.add_argument("--supervisor-resident-mib", type=int, required=True)
    args = parser.parse_args()

    pathlib.Path(args.state_root).mkdir(parents=True, exist_ok=True)
    service = Service(args)

    def handle_signal(signum, frame):
        service.stop.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    service.serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

