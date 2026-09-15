#!/usr/bin/env python3
import argparse, json, os, signal, socket, threading, time

class Manager:
    def __init__(self, sock_path, state_path, config_path, event_path):
        self.sock_path, self.state_path, self.event_path = sock_path, state_path, event_path
        cfg = json.load(open(config_path)); self.lock = threading.Lock()
        self.state = {"resource_instance": cfg["resource_instance"], "totals": cfg["features"], "leases": {}, "events": [], "sequence": 0}
        self.stop_event = threading.Event(); os.makedirs(os.path.dirname(sock_path), exist_ok=True); os.makedirs(os.path.dirname(state_path), exist_ok=True)
        try: os.unlink(sock_path)
        except FileNotFoundError: pass
        open(event_path, "w").close(); os.chmod(event_path, 0o600); self.save()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); self.server.bind(sock_path); os.chmod(sock_path, 0o666); self.server.listen(32); self.server.settimeout(0.4)
    def save(self):
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as fh: json.dump(self.state, fh, sort_keys=True)
        os.replace(tmp, self.state_path); os.chmod(self.state_path, 0o600)
    def record(self, event):
        event = {"ts": time.time(), **event}; self.state["events"].append(event)
        with open(self.event_path, "a") as fh: fh.write(json.dumps(event, sort_keys=True) + "\n")
    def free(self):
        used = {name: 0 for name in self.state["totals"]}
        for lease in self.state["leases"].values():
            for name, count in lease["features"].items(): used[name] = used.get(name, 0) + count
        return {name: self.state["totals"][name] - used.get(name, 0) for name in self.state["totals"]}
    def handle(self, req):
        with self.lock:
            op = req.get("op")
            if op == "ping": return {"ok": True, "resource_instance": self.state["resource_instance"]}
            if op == "status": return {"ok": True, "resource_instance": self.state["resource_instance"], "totals": self.state["totals"], "free": self.free(), "leases": self.state["leases"], "events": self.state["events"][-30:]}
            if op == "acquire":
                requested = {str(k): int(v) for k, v in req.get("features", {}).items()}; free = self.free(); deficits = {k: requested[k] - free.get(k, 0) for k in requested if requested[k] > free.get(k, 0)}
                if deficits:
                    limiting = sorted(deficits)[0]; self.record({"kind": "checkout_denied", "owner": req.get("owner", "unknown"), "requested": requested, "deficits": deficits, "limiting_feature": limiting, "rollback": True}); self.save()
                    return {"ok": False, "reason": "bundle_unavailable", "limiting_feature": limiting, "deficits": deficits, "free": free, "rollback": True}
                self.state["sequence"] += 1; checkout = f"seat-{self.state['sequence']:04d}"
                self.state["leases"][checkout] = {"owner": req.get("owner", "unknown"), "features": requested, "job": req.get("job", ""), "acquired_at": time.time(), "last_heartbeat": time.time()}
                self.record({"kind": "checkout_granted", "checkout_id": checkout, "owner": req.get("owner", "unknown"), "features": requested}); self.save()
                return {"ok": True, "checkout_id": checkout, "features": requested, "free": self.free()}
            if op == "heartbeat":
                checkout = req.get("checkout_id")
                if checkout in self.state["leases"]: self.state["leases"][checkout]["last_heartbeat"] = time.time(); self.save(); return {"ok": True}
                return {"ok": False, "reason": "unknown_checkout"}
            if op == "release":
                checkout = req.get("checkout_id"); lease = self.state["leases"].pop(checkout, None)
                if lease: self.record({"kind": "checkout_released", "checkout_id": checkout, "owner": lease["owner"], "result": req.get("result", "normal")}); self.save(); return {"ok": True}
                return {"ok": False, "reason": "unknown_checkout"}
            return {"ok": False, "reason": "unknown_operation"}
    def serve(self):
        while not self.stop_event.is_set():
            try: conn, _ = self.server.accept()
            except socket.timeout: continue
            except OSError: break
            threading.Thread(target=self.client, args=(conn,), daemon=True).start()
    def client(self, conn):
        try:
            data = b""
            while not data.endswith(b"\n"):
                part = conn.recv(65536)
                if not part: break
                data += part
            if data: conn.sendall((json.dumps(self.handle(json.loads(data.decode()))) + "\n").encode())
        except Exception as exc:
            try: conn.sendall((json.dumps({"ok": False, "reason": "server_error", "detail": str(exc)}) + "\n").encode())
            except OSError: pass
        finally: conn.close()
    def close(self):
        self.stop_event.set()
        try: self.server.close()
        except OSError: pass
        try: os.unlink(self.sock_path)
        except FileNotFoundError: pass

def client(sock_path, op):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10); sock.connect(sock_path); sock.sendall((json.dumps({"op": op}) + "\n").encode()); data = b""
        while not data.endswith(b"\n"):
            part = sock.recv(65536)
            if not part: break
            data += part
    print(data.decode(), end="")

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--socket", required=True); ap.add_argument("--state", default=""); ap.add_argument("--config", default=""); ap.add_argument("--log", default=""); ap.add_argument("--client-op", choices=["status", "ping"])
    args = ap.parse_args()
    if args.client_op: client(args.socket, args.client_op); return 0
    mgr = Manager(args.socket, args.state, args.config, args.log); signal.signal(signal.SIGTERM, lambda *_: mgr.close()); signal.signal(signal.SIGINT, lambda *_: mgr.close()); mgr.serve(); return 0
if __name__ == "__main__": raise SystemExit(main())
