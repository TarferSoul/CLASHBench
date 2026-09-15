#!/usr/bin/env python3
import json, os, signal, socket, sys, threading, time
from pathlib import Path
host, port, worker, run_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
pid=os.getpid(); stop_event=threading.Event(); requests=0
def atomic(name, value):
    tmp=run_dir/(name+".tmp"); tmp.write_text(value, encoding="ascii"); tmp.replace(run_dir/name)
def heartbeat():
    while not stop_event.is_set(): atomic(f"worker_{worker}.heartbeat", f"{time.time():.6f}\n"); stop_event.wait(.2)
sock=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1); sock.bind((host, port)); sock.settimeout(.2)
link=os.readlink(f"/proc/self/fd/{sock.fileno()}")
atomic(f"worker_{worker}.pid", f"{pid}\n"); atomic(f"worker_{worker}.starttime", Path(f"/proc/{pid}/stat").read_text().split()[21]+"\n")
atomic(f"worker_{worker}.socket_inode", link[8:-1]+"\n"); atomic(f"worker_{worker}.requests", "0\n"); atomic(f"worker_{worker}.heartbeat", f"{time.time():.6f}\n")
threading.Thread(target=heartbeat, daemon=True).start(); atomic(f"worker_{worker}.ready", "ready\n")
routes={"reranker-v4":"http://127.0.0.1:28110/v1/rerank","embedder-v3":"http://127.0.0.1:28111/v1/embed"}
def stop(*_): stop_event.set()
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
while not stop_event.is_set():
    try: raw, addr=sock.recvfrom(8192)
    except socket.timeout: continue
    except OSError: break
    requests += 1; atomic(f"worker_{worker}.requests", f"{requests}\n")
    try:
        query=json.loads(raw); model=query.get("model", "")
        payload={"ok": model in routes, "service":"model-route-resolver", "model":model, "route":routes.get(model, ""), "worker":worker}
    except Exception: payload={"ok":False, "service":"model-route-resolver", "error":"invalid-json", "worker":worker}
    sock.sendto(json.dumps(payload, separators=(",", ":")).encode(), addr)
sock.close()
