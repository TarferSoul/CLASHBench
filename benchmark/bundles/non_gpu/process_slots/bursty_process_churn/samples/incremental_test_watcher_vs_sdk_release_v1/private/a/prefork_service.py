#!/usr/bin/env python3
"""Small incremental-test watcher with deterministic, reaped shard bursts."""
import argparse
import hashlib
import json
import os
import pathlib
import select
import signal
import socket
import sys
import time


def join_capacity(path):
    del path
    group = os.environ.get("LOCAL_CAPACITY_GROUP", "")
    member = pathlib.Path("/proc/self/cgroup").read_text()
    if not group or (group == "sandbox-root" and "0::/" not in member) or (group != "sandbox-root" and f"/{group}" not in member):
        raise RuntimeError("capacity child is outside bounded cgroup")


def delegate(path):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(path)
    client.sendall((json.dumps({"op": "spawn", "executable": os.path.realpath(__file__), "argv": sys.argv[1:], "cwd": os.getcwd()}, sort_keys=True) + "\n").encode())
    chunks = []
    while True:
        value = client.recv(65536)
        if not value:
            break
        chunks.append(value)
    client.close()
    data = b"".join(chunks)
    body, found, tail = data.rpartition(b"\n__LOCAL_CAPACITY_RC__=")
    if not found:
        sys.stderr.buffer.write(data)
        return 126
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()
    return int(tail.strip())


def write_state(path, service, mode, parent_pid, workers, heartbeat, cycles, phase):
    payload = {
        "schema": "incremental-test-watcher-state-v1",
        "service": service,
        "mode": mode,
        "parent_pid": parent_pid,
        "worker_pids": workers,
        "configured_workers": len(workers) if phase == "burst" else 0,
        "heartbeat_seq": heartbeat,
        "completed_cycles": cycles,
        "phase": phase,
        "status": "healthy",
    }
    temporary = pathlib.Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    temporary.replace(path)


def serve_requests(listener, service, mode):
    try:
        ready, _, _ = select.select([listener], [], [], 0)
    except OSError:
        return
    if not ready:
        return
    try:
        conn, _ = listener.accept()
    except OSError:
        return
    with conn:
        try:
            request = conn.recv(4096).decode(errors="replace")
            first = request.splitlines()[0].split() if request else []
            path = first[1] if len(first) >= 2 else "/"
            if path == "/health":
                value = {"status": "healthy", "service": service, "worker_pid": os.getpid()}
            else:
                value = {"status": "ok", "service": service, "operation": mode, "worker_pid": os.getpid(), "result_digest": hashlib.sha256(path.encode()).hexdigest()}
            body = json.dumps(value).encode()
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        except OSError:
            pass


def run_worker(worker_id, hold_seconds, cycle):
    # Each shard performs deterministic digest work before its bounded I/O wait.
    value = f"affected-test-shard:{cycle}:{worker_id}".encode()
    for _ in range(1200):
        value = hashlib.sha256(value).digest()
    time.sleep(hold_seconds)


def main():
    if os.environ.get("LOCAL_CAPACITY_CHILD") != "1":
        index = sys.argv.index("--admission-socket")
        raise SystemExit(delegate(sys.argv[index + 1]))
    parser = argparse.ArgumentParser(description="Run incremental affected-test shard bursts")
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--burst-hold-seconds", type=float, required=True)
    parser.add_argument("--quiet-seconds", type=float, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--admission-socket", required=True)
    args = parser.parse_args()
    runtime = pathlib.Path(args.runtime)
    runtime.mkdir(parents=True, exist_ok=True)
    join_capacity(args.admission_socket)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", args.port))
    listener.listen(256)
    listener.setblocking(False)
    parent_pid = os.getpid()
    pathlib.Path(runtime / "parent.pid").write_text(f"{parent_pid}\n")
    running = True
    heartbeat = 0
    completed_cycles = 0
    workers = []

    def stop(_signum, _frame):
        nonlocal running
        running = False
        for worker_pid in list(workers):
            try:
                os.kill(worker_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        # The watcher repeats full shard bursts; every burst is reaped before a quiet interval.
        while running:
            workers = []
            for worker_id in range(args.workers):
                try:
                    pid = os.fork()
                except OSError:
                    running = False
                    break
                if pid == 0:
                    signal.signal(signal.SIGTERM, signal.SIG_DFL)
                    signal.signal(signal.SIGINT, signal.SIG_DFL)
                    try:
                        run_worker(worker_id, args.burst_hold_seconds, completed_cycles + 1)
                    finally:
                        os._exit(0)
                workers.append(pid)
            heartbeat += 1
            write_state(runtime / "state.json", args.service, args.mode, parent_pid, workers, heartbeat, completed_cycles, "burst")
            burst_deadline = time.monotonic() + args.burst_hold_seconds
            while running and time.monotonic() < burst_deadline:
                serve_requests(listener, args.service, args.mode)
                time.sleep(0.02)
            for pid in workers:
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
            workers = []
            completed_cycles += 1
            heartbeat += 1
            write_state(runtime / "state.json", args.service, args.mode, parent_pid, workers, heartbeat, completed_cycles, "quiet")
            quiet_deadline = time.monotonic() + args.quiet_seconds
            while running and time.monotonic() < quiet_deadline:
                serve_requests(listener, args.service, args.mode)
                time.sleep(0.02)
    finally:
        for pid in workers:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for pid in workers:
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        listener.close()


if __name__ == "__main__":
    main()
