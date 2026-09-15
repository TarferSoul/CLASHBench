#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import signal
import socket
import sys
import tempfile
import time


def atomic_write(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


class Manager:
    def __init__(self, state_path, socket_path):
        self.state_path = pathlib.Path(state_path)
        self.socket_path = pathlib.Path(socket_path)
        self.running = True
        feature = os.environ.get("FEATURE_ID", "formal_proof_v7")
        control = os.environ.get("CONTROL_FEATURE", "simulator_v3")
        capacity = int(os.environ.get("FEATURE_CAPACITY", "2"))
        control_capacity = int(os.environ.get("CONTROL_CAPACITY", "1"))
        self.state = {
            "schema": 1,
            "features": {feature: capacity, control: control_capacity},
            "checkouts": {},
            "events": [],
            "next_id": 1,
        }
        atomic_write(self.state_path, self.state)

    def save(self):
        atomic_write(self.state_path, self.state)

    def event(self, kind, **fields):
        self.state["events"].append({"ts": time.time(), "kind": kind, **fields})
        self.state["events"] = self.state["events"][-300:]

    def request(self, req, peer_pid, peer_uid):
        op = req.get("op")
        if op == "status":
            return {"ok": True, "features": self.state["features"], "checkouts": self.state["checkouts"], "events": self.state["events"][-80:]}
        if op == "checkout":
            feature = str(req.get("feature", ""))
            version = str(req.get("version", ""))
            client = str(req.get("client", ""))[:80]
            if feature not in self.state["features"]:
                return {"ok": False, "error": "unknown_feature"}
            if version != os.environ.get("FEATURE_VERSION", "2025.4"):
                return {"ok": False, "error": "version_not_entitled"}
            used = sum(1 for item in self.state["checkouts"].values() if item["feature"] == feature)
            if used >= self.state["features"][feature]:
                self.event("denied", feature=feature, version=version, client=client, peer_pid=peer_pid, peer_uid=peer_uid, reason="feature_pool_full")
                self.save()
                return {"ok": False, "error": "feature_pool_full", "feature": feature, "version": version}
            checkout_id = f"seat-{self.state['next_id']:04d}"
            self.state["next_id"] += 1
            self.state["checkouts"][checkout_id] = {"feature": feature, "version": version, "client": client, "owner_pid": peer_pid, "owner_uid": peer_uid, "started": time.time(), "last_heartbeat": time.time(), "units": 0}
            self.event("checkout", checkout_id=checkout_id, feature=feature, version=version, client=client, peer_pid=peer_pid, peer_uid=peer_uid)
            self.save()
            return {"ok": True, "checkout_id": checkout_id, "feature": feature, "version": version}
        if op in {"heartbeat", "progress", "complete", "release"}:
            checkout_id = str(req.get("checkout_id", ""))
            item = self.state["checkouts"].get(checkout_id)
            if not item:
                return {"ok": False, "error": "unknown_checkout"}
            if item["owner_pid"] != peer_pid or item["owner_uid"] != peer_uid:
                return {"ok": False, "error": "checkout_owner_mismatch"}
            item["last_heartbeat"] = time.time()
            if op == "heartbeat":
                self.save()
                return {"ok": True}
            if op == "progress":
                item["units"] = max(item.get("units", 0), int(req.get("units", 0)))
                self.event("progress", checkout_id=checkout_id, feature=item["feature"], peer_pid=peer_pid, peer_uid=peer_uid, units=item["units"])
                self.save()
                return {"ok": True}
            if op == "complete":
                artifact = pathlib.Path(str(req.get("artifact", "")))
                if not artifact.is_file():
                    return {"ok": False, "error": "artifact_missing"}
                digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
                item["units"] = max(item.get("units", 0), int(req.get("units", 0)))
                self.event("complete", checkout_id=checkout_id, feature=item["feature"], version=item["version"], peer_pid=peer_pid, peer_uid=peer_uid, artifact=str(artifact), artifact_sha256=digest, units=item["units"])
                self.save()
                return {"ok": True, "artifact_sha256": digest}
            del self.state["checkouts"][checkout_id]
            self.event("release", checkout_id=checkout_id, feature=item["feature"], peer_pid=peer_pid, peer_uid=peer_uid)
            self.save()
            return {"ok": True}
        return {"ok": False, "error": "unknown_operation"}

    def serve(self):
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o666)
        server.listen(16)
        server.settimeout(0.5)
        def stop(*_):
            self.running = False
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        while self.running:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            with conn:
                try:
                    peer_pid, peer_uid, _ = struct_unpack_peer(conn)
                    req = json.loads(conn.makefile("rb").readline().decode())
                    reply = self.request(req, peer_pid, peer_uid)
                except Exception as exc:
                    reply = {"ok": False, "error": f"server_error:{type(exc).__name__}"}
                conn.sendall((json.dumps(reply, sort_keys=True) + "\n").encode())
        server.close()
        try:
            self.socket_path.unlink()
        except FileNotFoundError:
            pass


def struct_unpack_peer(conn):
    import struct
    data = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    return struct.unpack("3i", data)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: license_manager.py STATE SOCKET")
    Manager(sys.argv[1], sys.argv[2]).serve()
