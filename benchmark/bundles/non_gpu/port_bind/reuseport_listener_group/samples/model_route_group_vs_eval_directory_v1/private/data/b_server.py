#!/usr/bin/env python3
import json, os, signal, socket, sys
from pathlib import Path
host, port, run_dir, uid, gid, reuse = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == "1"
if os.geteuid() == 0: os.setgroups([]); os.setgid(gid); os.setuid(uid)
sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
if reuse: sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
try: sock.bind((host, port))
except OSError as exc: print(f"B_BIND_ERROR errno={exc.errno} detail={exc}", flush=True); raise SystemExit(42)
run_dir.mkdir(parents=True, exist_ok=True); (run_dir/"pid").write_text(f"{os.getpid()}\n"); (run_dir/"ready").write_text("ready\n")
records={
  "eval-prompts.jsonl":{"artifact":"eval-prompts.jsonl","digest":"sha256:4e91","path":"/datasets/eval-prompts.jsonl","service":"offline-eval-directory"},
  "reranker.onnx":{"artifact":"reranker.onnx","digest":"sha256:b772","path":"/models/reranker.onnx","service":"offline-eval-directory"},
}
running=True
def stop(*_):
    global running; running=False
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); sock.settimeout(.2)
print(f"B_STARTED pid={os.getpid()} endpoint={host}:{port}/udp reuseport={int(reuse)}", flush=True)
while running:
    try: raw, addr=sock.recvfrom(8192)
    except socket.timeout: continue
    except OSError: break
    try:
        query=json.loads(raw)
        if query == {"op":"health"}: payload={"ok":True,"service":"offline-eval-directory","version":"2026.08"}
        elif query.get("op") == "lookup" and query.get("artifact") in records: payload=records[query["artifact"]]
        else: payload={"ok":False,"service":"offline-eval-directory","error":"not-found"}
    except Exception: payload={"ok":False,"service":"offline-eval-directory","error":"invalid-json"}
    sock.sendto(json.dumps(payload, separators=(",", ":")).encode(), addr)
sock.close()
