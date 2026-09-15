#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import signal
import socket
import sys
import time
import urllib.parse


def proc_start_time(pid):
    try:
        text = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        rest = text[text.rfind(") ") + 2 :].split()
        return int(rest[19])
    except Exception:
        return None


def atomic_json(path, value):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def append_jsonl(path, value):
    line = json.dumps(value, sort_keys=True) + "\n"
    fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def response(sock, status, body, content_type="application/json"):
    if isinstance(body, str):
        raw = body.encode("utf-8")
    else:
        raw = body
    headers = [
        f"HTTP/1.1 {status}",
        f"Content-Type: {content_type}",
        f"Content-Length: {len(raw)}",
        "Connection: close",
        "",
        "",
    ]
    sock.sendall("\r\n".join(headers).encode("utf-8") + raw)


def send_chunk(sock, payload):
    raw = payload.encode("utf-8")
    sock.sendall(f"{len(raw):x}\r\n".encode("ascii") + raw + b"\r\n")


class Service:
    def __init__(self, args):
        self.host = args.host
        self.port = args.port
        self.worker_count = args.workers
        self.interval = args.interval
        self.state_dir = os.path.abspath(args.state_dir)
        self.fixture = json.load(open(args.fixture, "r", encoding="utf-8"))
        self.worker_dir = os.path.join(self.state_dir, "workers")
        self.dispatch_log = os.path.join(self.state_dir, "dispatch.jsonl")
        self.children = []
        self.stop = False

    def setup_dirs(self):
        os.makedirs(self.worker_dir, mode=0o700, exist_ok=True)
        for name in ("master.json", "dispatch.jsonl"):
            path = os.path.join(self.state_dir, name)
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
        for name in os.listdir(self.worker_dir):
            try:
                os.unlink(os.path.join(self.worker_dir, name))
            except OSError:
                pass

    def serve(self):
        self.setup_dirs()
        signal.signal(signal.SIGTERM, self.handle_stop)
        signal.signal(signal.SIGINT, self.handle_stop)
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server_sock.bind((self.host, self.port))
        server_sock.listen(64)
        server_sock.set_inheritable(True)
        for slot in range(self.worker_count):
            pid = os.fork()
            if pid == 0:
                self.worker_loop(server_sock, slot)
                os._exit(0)
            self.children.append(pid)
        atomic_json(os.path.join(self.state_dir, "master.json"), {
            "pid": os.getpid(),
            "start_time": proc_start_time(os.getpid()),
            "host": self.host,
            "port": self.port,
            "worker_count": self.worker_count,
            "worker_pids": self.children,
            "started_at": now_iso(),
        })
        while not self.stop:
            try:
                dead, _ = os.waitpid(-1, os.WNOHANG)
                if dead > 0 and dead in self.children:
                    self.children.remove(dead)
            except ChildProcessError:
                break
            time.sleep(0.2)
        self.shutdown_children()

    def handle_stop(self, _signum, _frame):
        self.stop = True

    def shutdown_children(self):
        for pid in list(self.children):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while self.children and time.monotonic() < deadline:
            try:
                dead, _ = os.waitpid(-1, os.WNOHANG)
                if dead > 0 and dead in self.children:
                    self.children.remove(dead)
                    continue
            except ChildProcessError:
                break
            time.sleep(0.1)
        for pid in list(self.children):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def worker_state_path(self):
        return os.path.join(self.worker_dir, f"{os.getpid()}.json")

    def write_worker_state(self, state):
        base = {
            "worker_pid": os.getpid(),
            "worker_start_time": proc_start_time(os.getpid()),
            "updated_at": time.time(),
        }
        base.update(state)
        atomic_json(self.worker_state_path(), base)

    def worker_loop(self, server_sock, slot):
        signal.signal(signal.SIGTERM, lambda _s, _f: sys.exit(0))
        self.write_worker_state({"slot": slot, "phase": "idle"})
        while True:
            try:
                conn, addr = server_sock.accept()
            except OSError as exc:
                if exc.errno in (errno.EINTR, errno.EBADF):
                    return
                raise
            try:
                self.handle_connection(conn, addr, slot)
            except Exception as exc:
                try:
                    response(conn, "500 Internal Server Error", json.dumps({"error": str(exc)}))
                except Exception:
                    pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass
                self.write_worker_state({"slot": slot, "phase": "idle"})

    def read_request(self, conn):
        conn.settimeout(5)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        text = data.decode("iso-8859-1", errors="replace")
        line = text.splitlines()[0] if text.splitlines() else ""
        parts = line.split()
        if len(parts) < 2:
            return "GET", "/", {}
        method, target = parts[0], parts[1]
        parsed = urllib.parse.urlparse(target)
        return method, parsed.path, urllib.parse.parse_qs(parsed.query)

    def handle_connection(self, conn, addr, slot):
        method, path, query = self.read_request(conn)
        request_id = f"req-{int(time.time() * 1000)}-{os.getpid()}-{slot}"
        client_tuple = f"{addr[0]}:{addr[1]}"
        append_jsonl(self.dispatch_log, {
            "request_id": request_id,
            "worker_pid": os.getpid(),
            "worker_start_time": proc_start_time(os.getpid()),
            "client_tuple": client_tuple,
            "method": method,
            "path": path,
            "query": query,
            "accepted_at": time.time(),
        })
        if method == "GET" and path.startswith("/api/ci/jobs/") and path.endswith("/logs"):
            job_id = path.split("/")[4]
            cursor = int((query.get("cursor") or ["0"])[0])
            follow = (query.get("follow") or ["0"])[0]
            if follow != "1" or job_id not in self.fixture["jobs"]:
                response(conn, "404 Not Found", json.dumps({"error": "unknown log stream"}))
                return
            self.stream_job(conn, slot, request_id, client_tuple, job_id, cursor)
            return
        if method == "GET" and path == f"/api/ci/builds/{self.fixture['build_id']}/failure-timeline":
            self.timeline_response(conn, slot, request_id, client_tuple)
            return
        if method == "GET" and path == "/healthz":
            response(conn, "200 OK", json.dumps({"ok": True, "workers": self.worker_count}))
            return
        response(conn, "404 Not Found", json.dumps({"error": "not found"}))

    def stream_job(self, conn, slot, request_id, client_tuple, job_id, cursor):
        headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/plain; charset=utf-8",
            "Transfer-Encoding: chunked",
            "Cache-Control: no-store",
            "Connection: keep-alive",
            "",
            "",
        ]
        conn.sendall("\r\n".join(headers).encode("utf-8"))
        job = self.fixture["jobs"][job_id]
        offset = cursor
        chunk_count = 0
        heartbeat_count = 0
        sequence = 0
        while True:
            step = job["steps"][sequence % len(job["steps"])]
            if sequence % 3 == 2:
                heartbeat_count += 1
                payload = (
                    f"heartbeat build={self.fixture['build_id']} job={job_id} "
                    f"seq={sequence} cursor={offset}\n"
                )
            else:
                payload = (
                    f"chunk build={self.fixture['build_id']} job={job_id} "
                    f"phase={step['phase']} step={step['step_name']} "
                    f"first_failed_test={step['first_failed_test'] or '-'} "
                    f"cursor={offset} excerpt={step['excerpt']}\n"
                )
            try:
                send_chunk(conn, payload)
            except OSError:
                return
            chunk_count += 1
            offset += len(payload.encode("utf-8"))
            self.write_worker_state({
                "slot": slot,
                "phase": "streaming",
                "request_id": request_id,
                "client_tuple": client_tuple,
                "job_id": job_id,
                "current_byte_offset": offset,
                "chunk_count": chunk_count,
                "heartbeat_count": heartbeat_count,
                "last_step_name": step["step_name"],
            })
            sequence += 1
            time.sleep(self.interval)

    def timeline_response(self, conn, slot, request_id, client_tuple):
        self.write_worker_state({
            "slot": slot,
            "phase": "timeline_export",
            "request_id": request_id,
            "client_tuple": client_tuple,
        })
        events = []
        sections = []
        for job_id, job in self.fixture["jobs"].items():
            cursor = int(job["starting_cursor"])
            for step in job["steps"]:
                text = f"{self.fixture['build_id']}:{job_id}:{step['phase']}:{step['step_name']}:{step['excerpt']}"
                digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
                event = {
                    "job_id": job_id,
                    "phase": step["phase"],
                    "step_name": step["step_name"],
                    "first_failed_test": step["first_failed_test"],
                    "log_excerpt_sha256": digest,
                    "source_cursor": cursor,
                }
                events.append(event)
                cursor += len(step["excerpt"].encode("utf-8")) + 40
        for phase in self.fixture["required_phases"]:
            phase_events = [item for item in events if item["phase"] == phase]
            sections.append({
                "phase": phase,
                "event_count": len(phase_events),
                "job_ids": sorted({item["job_id"] for item in phase_events}),
            })
        body = {
            "build_id": self.fixture["build_id"],
            "generated_at": now_iso(),
            "include_logs": True,
            "format": "json",
            "sections": sections,
            "events": events,
        }
        time.sleep(0.2)
        response(conn, "200 OK", json.dumps(body, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--interval", type=float, default=0.35)
    args = parser.parse_args()
    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    Service(args).serve()


if __name__ == "__main__":
    main()

