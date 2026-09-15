#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import socket
import sys
import time

def join_capacity(path):
    del path
    group = os.environ.get("LOCAL_CAPACITY_GROUP", "")
    member = pathlib.Path("/proc/self/cgroup").read_text()
    if not group or (group == "sandbox-root" and "0::/" not in member) or (group != "sandbox-root" and f"/{group}" not in member): raise RuntimeError("capacity child is outside bounded cgroup")
def delegate(path):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); client.connect(path)
    client.sendall((json.dumps({"op": "spawn", "cgroup": os.environ.get("LOCAL_CAPACITY_GROUP", ""), "executable": os.path.realpath(__file__), "argv": sys.argv[1:], "cwd": os.getcwd()}, sort_keys=True) + "\n").encode()); chunks = []
    while True:
        value = client.recv(65536)
        if not value: break
        chunks.append(value)
    client.close(); data = b"".join(chunks); body, found, tail = data.rpartition(b"\n__LOCAL_CAPACITY_RC__=")
    if not found: sys.stderr.buffer.write(data); return 126
    sys.stdout.buffer.write(body); sys.stdout.buffer.flush(); return int(tail.strip())
def serve(listener, service, mode):
    running = True
    def stop(_signum, _frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); listener.settimeout(0.3)
    while running:
        try: conn, _ = listener.accept()
        except socket.timeout: continue
        except OSError: break
        with conn:
            try:
                request = conn.recv(4096).decode(errors="replace"); first = request.splitlines()[0].split() if request else []
                path = first[1] if len(first) >= 2 else "/"
                if path == "/health": body_value = {"status": "healthy", "service": service, "worker_pid": os.getpid()}
                else: body_value = {"status": "ok", "service": service, "operation": mode, "worker_pid": os.getpid(), "result_digest": hashlib.sha256(path.encode()).hexdigest()}
                body = json.dumps(body_value).encode()
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            except OSError: pass
def main():
    if os.environ.get("LOCAL_CAPACITY_CHILD") != "1":
        index = sys.argv.index("--admission-socket"); raise SystemExit(delegate(sys.argv[index + 1]))
    parser = argparse.ArgumentParser(); parser.add_argument("--runtime", required=True); parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--port", type=int, required=True); parser.add_argument("--service", required=True); parser.add_argument("--mode", required=True)
    parser.add_argument("--admission-socket", required=True); args = parser.parse_args(); runtime = pathlib.Path(args.runtime); runtime.mkdir(parents=True, exist_ok=True)
    join_capacity(args.admission_socket)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", args.port)); listener.listen(256); workers = []
    for _ in range(args.workers):
        pid = os.fork()
        if pid == 0: serve(listener, args.service, args.mode); os._exit(0)
        workers.append(pid)
    listener.close(); running = True
    def stop(_signum, _frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    pathlib.Path(runtime / "parent.pid").write_text(f"{os.getpid()}\n"); heartbeat = 0
    while running:
        heartbeat += 1; live = [pid for pid in workers if pathlib.Path(f"/proc/{pid}").exists()]
        payload = {"schema": "warm-prefork-service-state-v1", "service": args.service, "mode": args.mode,
                   "parent_pid": os.getpid(), "worker_pids": live, "configured_workers": args.workers,
                   "heartbeat_seq": heartbeat, "port": args.port, "status": "healthy" if len(live) == args.workers else "degraded"}
        temporary = runtime / "state.json.tmp"; temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n"); temporary.replace(runtime / "state.json")
        if len(live) != args.workers: running = False; break
        time.sleep(0.25)
    for pid in workers:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    for pid in workers:
        try: os.waitpid(pid, 0)
        except ChildProcessError: pass
if __name__ == "__main__": main()
