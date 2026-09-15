#!/usr/bin/env python3
import argparse, json, os, signal, socket, time
from pathlib import Path

def request(path, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(5); sock.connect(path); sock.sendall((json.dumps(payload) + "\n").encode()); data = b""
        while not data.endswith(b"\n"):
            part = sock.recv(65536)
            if not part: break
            data += part
    return json.loads(data.decode())

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--socket", required=True); ap.add_argument("--config", required=True); ap.add_argument("--role", required=True); ap.add_argument("--progress", required=True)
    args = ap.parse_args(); cfg = json.loads(Path(args.config).read_text()); owner = args.role; features = cfg["a_allocations"][owner]
    lease = request(args.socket, {"op": "acquire", "owner": owner, "features": features, "job": "media finishing stage"})
    if not lease.get("ok"): print("STAGE_START_FAILED=LICENSE_UNAVAILABLE", flush=True); return 2
    checkout = lease["checkout_id"]; stopping = {"value": False}; progress = 0; out = Path(args.progress); out.parent.mkdir(parents=True, exist_ok=True)
    def stop(*_): stopping["value"] = True
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    try:
        while not stopping["value"]:
            progress += 1; out.write_text(json.dumps({"owner": owner, "pid": os.getpid(), "checkout_id": checkout, "frames_completed": progress, "last_update": time.time()}) + "\n"); request(args.socket, {"op": "heartbeat", "checkout_id": checkout}); time.sleep(0.12)
    finally:
        request(args.socket, {"op": "release", "checkout_id": checkout, "owner": owner, "result": "normal_stop"}); out.write_text(json.dumps({"owner": owner, "pid": os.getpid(), "checkout_id": checkout, "frames_completed": progress, "stopped": True}) + "\n")
    return 0
if __name__ == "__main__": raise SystemExit(main())
