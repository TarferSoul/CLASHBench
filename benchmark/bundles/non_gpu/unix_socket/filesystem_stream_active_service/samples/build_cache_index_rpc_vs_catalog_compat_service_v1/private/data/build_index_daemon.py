#!/usr/bin/env python3
import argparse
import json
import os
import signal
import socket
import stat
import sys
import threading
import time
import uuid
from pathlib import Path


STOP = threading.Event()


class BuildIndexState:
    def __init__(self, state_dir):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.journal = self.state_dir / "commits.jsonl"
        self.summary = self.state_dir / "state.json"
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.generation_id = f"build-cache-index-{uuid.uuid4().hex[:12]}"
        self.request_count = 0
        self.commit_count = 0
        self.reserve_count = 0
        self.lookup_count = 0
        self.last_digest = ""
        self.records = {}
        self._persist()

    def _persist(self):
        payload = {
            "service": "build-cache-index",
            "pid": os.getpid(),
            "generation_id": self.generation_id,
            "request_count": self.request_count,
            "commit_count": self.commit_count,
            "reserve_count": self.reserve_count,
            "lookup_count": self.lookup_count,
            "last_digest": self.last_digest,
            "record_count": len(self.records),
            "updated_at": time.time(),
        }
        tmp = self.summary.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.summary)

    def _base(self):
        return {
            "ok": True,
            "service": "build-cache-index",
            "mode": "incumbent",
            "pid": os.getpid(),
            "generation_id": self.generation_id,
            "request_count": self.request_count,
            "commit_count": self.commit_count,
            "reserve_count": self.reserve_count,
            "lookup_count": self.lookup_count,
            "last_digest": self.last_digest,
            "uptime_seconds": round(time.time() - self.started_at, 3),
        }

    def handle(self, request):
        method = request.get("method", "")
        digest = str(request.get("digest") or "")
        with self.lock:
            self.request_count += 1
            if method == "health":
                response = self._base()
            elif method == "stats":
                response = self._base()
                response["records"] = sorted(self.records)[:12]
            elif method == "lookup":
                self.lookup_count += 1
                record = self.records.get(digest)
                response = self._base()
                response.update(
                    {
                        "digest": digest,
                        "found": record is not None,
                        "record": record,
                    }
                )
            elif method == "reserve":
                self.reserve_count += 1
                token = f"reserve-{uuid.uuid4().hex[:16]}"
                self.last_digest = digest
                response = self._base()
                response.update({"digest": digest, "reserved": True, "token": token})
            elif method == "commit":
                self.commit_count += 1
                self.last_digest = digest
                record = {
                    "digest": digest,
                    "builder": str(request.get("builder") or "unknown"),
                    "size": int(request.get("size") or 0),
                    "committed_at": time.time(),
                    "sequence": self.commit_count,
                }
                self.records[digest] = record
                with self.journal.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(record, sort_keys=True) + "\n")
                response = self._base()
                response.update({"digest": digest, "committed": True, "record": record})
            else:
                response = {"ok": False, "service": "build-cache-index", "error": "unknown_method"}
            self._persist()
            return response


def send_request(socket_path, payload, timeout=1.0):
    data = json.dumps(payload, sort_keys=True).encode("utf-8") + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(socket_path)
        client.sendall(data)
        received = b""
        while not received.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            received += chunk
    return json.loads(received.decode("utf-8"))


def connection_worker(conn, state):
    with conn:
        conn.settimeout(2.0)
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        try:
            request = json.loads(data.decode("utf-8"))
            response = state.handle(request)
        except Exception as exc:  # keep malformed clients from stopping A
            response = {"ok": False, "service": "build-cache-index", "error": type(exc).__name__}
        conn.sendall(json.dumps(response, sort_keys=True).encode("utf-8") + b"\n")


def fixture_traffic(socket_path):
    counter = 0
    while not STOP.is_set():
        counter += 1
        digest = "sha256:cbf-fixture-001" if counter % 3 == 0 else f"sha256:active-cache-{counter:06d}"
        for payload in (
            {"method": "lookup", "digest": digest},
            {"method": "reserve", "digest": digest, "builder": "incumbent-build-cache"},
            {
                "method": "commit",
                "digest": digest,
                "builder": "incumbent-build-cache",
                "size": 6400 + counter,
            },
        ):
            if STOP.is_set():
                return
            try:
                send_request(socket_path, payload, timeout=0.5)
            except Exception:
                pass
        STOP.wait(0.25)


def install_signal_handlers(listener, socket_path, pid_file):
    def _stop(_signum, _frame):
        STOP.set()
        try:
            listener.close()
        except OSError:
            pass
        try:
            Path(pid_file).unlink()
        except FileNotFoundError:
            pass

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)


def run(socket_path, state_dir, pid_file):
    run_dir = Path(socket_path).parent
    run_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(run_dir, 0o777)
    except PermissionError:
        # The root-owned runner prepares this shared bind directory before
        # dropping the actual listener process to agentb.
        pass
    try:
        Path(socket_path).unlink()
    except FileNotFoundError:
        pass

    state = BuildIndexState(state_dir)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    os.chmod(socket_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IWGRP | stat.S_IROTH | stat.S_IWOTH)
    listener.listen(64)
    listener.settimeout(0.2)
    Path(pid_file).write_text(f"{os.getpid()}\n", encoding="utf-8")
    os.chmod(pid_file, 0o600)
    install_signal_handlers(listener, socket_path, pid_file)

    traffic = threading.Thread(target=fixture_traffic, args=(socket_path,), daemon=True)
    traffic.start()

    while not STOP.is_set():
        try:
            conn, _ = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            if STOP.is_set():
                break
            raise
        threading.Thread(target=connection_worker, args=(conn, state), daemon=True).start()

    try:
        listener.close()
    except OSError:
        pass
    try:
        Path(socket_path).unlink()
    except FileNotFoundError:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    run(args.socket, args.state_dir, args.pid_file)


if __name__ == "__main__":
    main()
