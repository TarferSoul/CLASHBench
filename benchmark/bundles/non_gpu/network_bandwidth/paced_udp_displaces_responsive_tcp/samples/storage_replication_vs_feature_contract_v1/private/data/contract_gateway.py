#!/usr/bin/env python3
"""Serve one deterministic checksum-addressed feature contract over TCP."""
import argparse, hashlib, json, os, pathlib, signal, socket, threading, time
from link_budget import SharedTokenBucket
running = True
def stop(*_):
    global running; running = False
def build(artifact_id, size):
    seed = hashlib.sha256(artifact_id.encode()).digest(); data = bytearray(); i = 0
    while len(data) < size: data.extend(hashlib.sha256(seed + i.to_bytes(8, "big")).digest()); i += 1
    return bytes(data[:size])
def main():
    p = argparse.ArgumentParser(); p.add_argument("--host", required=True); p.add_argument("--port", type=int, required=True); p.add_argument("--state", required=True); p.add_argument("--artifact-id", required=True); p.add_argument("--artifact-bytes", type=int, required=True); p.add_argument("--budget", required=True); a = p.parse_args()
    state = pathlib.Path(a.state); state.parent.mkdir(parents=True, exist_ok=True); bucket = SharedTokenBucket(a.budget); artifact = build(a.artifact_id, a.artifact_bytes); digest = hashlib.sha256(artifact).hexdigest(); started = time.time(); lock = threading.Lock(); counters = {"connections": 0, "completed_transfers": 0, "served_bytes": 0, "errors": 0}
    def write_state():
        with lock:
            value = {"healthy": running, "pid": os.getpid(), "started_at": started, "artifact_id": a.artifact_id, "artifact_bytes": len(artifact), "artifact_sha256": digest, "artifact_resident": True, "updated_at": time.time(), **counters}
        path = pathlib.Path(f"{state}.tmp.{os.getpid()}.{threading.get_ident()}"); path.write_text(json.dumps(value, sort_keys=True) + "\n"); os.chmod(path, 0o600); path.replace(state)
    def heartbeat():
        while running: write_state(); time.sleep(0.2)
    def handle(conn):
        sent = 0
        try:
            conn.settimeout(8.0); request = bytearray()
            while len(request) < 512 and not request.endswith(b"\n"):
                chunk = conn.recv(1)
                if not chunk: return
                request.extend(chunk)
            if request.decode(errors="replace").strip() != "GET " + a.artifact_id: conn.sendall(b'{"error":"unknown_artifact"}\n'); return
            conn.sendall((json.dumps({"artifact_id": a.artifact_id, "bytes": len(artifact), "sha256": digest}, sort_keys=True) + "\n").encode()); view = memoryview(artifact)
            while sent < len(artifact):
                count = min(65536, len(artifact) - sent)
                bucket.consume(count)
                count = conn.send(view[sent:sent + count])
                if count <= 0: raise ConnectionError("short send")
                sent += count
            with lock: counters["completed_transfers"] += 1
        except (BrokenPipeError, ConnectionError, OSError, socket.timeout):
            with lock: counters["errors"] += 1
        finally:
            with lock: counters["served_bytes"] += sent
            try: conn.close()
            except OSError: pass
            write_state()
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM); listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); listener.bind((a.host, a.port)); listener.listen(16); listener.settimeout(0.2); threading.Thread(target=heartbeat, daemon=True).start(); write_state()
    while running:
        try: conn, _ = listener.accept()
        except socket.timeout: continue
        except OSError: break
        with lock: counters["connections"] += 1
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
    listener.close(); write_state()
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); main()
