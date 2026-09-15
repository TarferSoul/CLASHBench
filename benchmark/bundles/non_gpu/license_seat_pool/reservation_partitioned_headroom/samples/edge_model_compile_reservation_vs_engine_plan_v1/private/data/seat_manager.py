#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import socket
import socketserver
import struct
import tempfile
import threading
import time
import uuid


def atomic_json(path, value):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".seat-state-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class SeatLedger:
    def __init__(self, policy_path, state_path):
        raw = open(policy_path, "rb").read()
        self.policy = json.loads(raw)
        self.policy_sha256 = hashlib.sha256(raw).hexdigest()
        self.state_path = state_path
        self.lock = threading.RLock()
        reservations = self.policy.get("reservations", [])
        reserved = sum(int(item["seats"]) for item in reservations)
        total = int(self.policy["total_seats"])
        if total <= 0 or reserved <= 0 or reserved >= total:
            raise ValueError("policy must have positive general and reserved capacity")
        self.general_capacity = total - reserved
        self.reserved_capacity = {
            str(item["identity"]): int(item["seats"]) for item in reservations
        }
        self.checkouts = {}
        self.events = []
        self.started_at = time.time()
        self.persist()

    def _alive(self, pid):
        try:
            os.kill(int(pid), 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    def _event(self, kind, **values):
        self.events.append({"kind": kind, "at": time.time(), **values})
        if len(self.events) > 1000:
            self.events = self.events[-1000:]

    def _prune(self):
        for checkout_id, checkout in list(self.checkouts.items()):
            if not self._alive(checkout["owner_pid"]):
                self._event(
                    "owner_exit_release",
                    checkout_id=checkout_id,
                    identity=checkout["identity"],
                    lane=checkout["lane"],
                    width=checkout["width"],
                    owner_pid=checkout["owner_pid"],
                )
                del self.checkouts[checkout_id]

    def counts(self):
        general_used = sum(
            item["width"] for item in self.checkouts.values() if item["lane"] == "general"
        )
        reserved_used = {}
        for identity, capacity in self.reserved_capacity.items():
            used = sum(
                item["width"]
                for item in self.checkouts.values()
                if item["lane"] == "reserved" and item["identity"] == identity
            )
            reserved_used[identity] = {
                "capacity": capacity,
                "used": used,
                "free": capacity - used,
            }
        total_used = general_used + sum(item["used"] for item in reserved_used.values())
        return {
            "total": int(self.policy["total_seats"]),
            "used": total_used,
            "free_total": int(self.policy["total_seats"]) - total_used,
            "general": {
                "capacity": self.general_capacity,
                "used": general_used,
                "free": self.general_capacity - general_used,
            },
            "reserved": reserved_used,
        }

    def snapshot(self):
        return {
            "schema_version": 1,
            "manager": self.policy["manager"],
            "feature": self.policy["feature"],
            "version": self.policy["version"],
            "policy_sha256": self.policy_sha256,
            "policy_mode": "fixed_reservation_partition",
            "started_at": self.started_at,
            "counts": self.counts(),
            "checkouts": self.checkouts,
            "events": self.events,
        }

    def persist(self):
        with self.lock:
            atomic_json(self.state_path, self.snapshot())

    def _owner(self, checkout_id, pid, uid):
        checkout = self.checkouts.get(checkout_id)
        return checkout if checkout and checkout["owner_pid"] == pid and checkout["owner_uid"] == uid else None

    def handle(self, request, pid, uid):
        with self.lock:
            self._prune()
            operation = request.get("op")
            if operation in {"status", "health"}:
                self.persist()
                return {"ok": True, **self.snapshot()}
            if operation == "checkout":
                identity = str(request.get("identity", ""))
                width = int(request.get("width", 1))
                feature = str(request.get("feature", ""))
                version = str(request.get("version", ""))
                if feature != self.policy["feature"] or version != self.policy["version"] or width <= 0:
                    self._event("invalid_request", identity=identity, owner_pid=pid)
                    self.persist()
                    return {"ok": False, "reason": "feature_or_width_invalid"}
                counts = self.counts()
                lane = None
                if identity in self.reserved_capacity:
                    if counts["reserved"][identity]["free"] >= width:
                        lane = "reserved"
                    elif counts["general"]["free"] >= width:
                        lane = "general"
                elif counts["general"]["free"] >= width:
                    lane = "general"
                if lane is None:
                    self._event(
                        "denied",
                        identity=identity,
                        feature=feature,
                        version=version,
                        width=width,
                        owner_pid=pid,
                        owner_uid=uid,
                        reason="no_eligible_seat",
                        free_total=counts["free_total"],
                        general_free=counts["general"]["free"],
                    )
                    self.persist()
                    return {
                        "ok": False,
                        "reason": "no_eligible_seat",
                        "free_total": counts["free_total"],
                        "general_free": counts["general"]["free"],
                        "reserved_free": sum(item["free"] for item in counts["reserved"].values()),
                    }
                checkout_id = "seat-" + uuid.uuid4().hex[:16]
                self.checkouts[checkout_id] = {
                    "identity": identity,
                    "feature": feature,
                    "version": version,
                    "width": width,
                    "lane": lane,
                    "owner_pid": pid,
                    "owner_uid": uid,
                    "created_at": time.time(),
                    "last_heartbeat": time.time(),
                    "work_units": 0,
                }
                self._event(
                    "granted",
                    checkout_id=checkout_id,
                    identity=identity,
                    lane=lane,
                    width=width,
                    owner_pid=pid,
                    owner_uid=uid,
                )
                self.persist()
                return {"ok": True, "checkout_id": checkout_id, "lane": lane}
            checkout_id = str(request.get("checkout_id", ""))
            checkout = self._owner(checkout_id, pid, uid)
            if not checkout:
                self._event("ownership_rejected", checkout_id=checkout_id, owner_pid=pid, owner_uid=uid)
                self.persist()
                return {"ok": False, "reason": "checkout_owner_mismatch"}
            if operation == "heartbeat":
                checkout["last_heartbeat"] = time.time()
            elif operation == "work":
                checkout["last_heartbeat"] = time.time()
                checkout["work_units"] = max(checkout["work_units"], int(request.get("unit", 0)))
                self._event(
                    "work",
                    checkout_id=checkout_id,
                    identity=checkout["identity"],
                    owner_pid=pid,
                    unit=checkout["work_units"],
                    digest=str(request.get("digest", "")),
                    item=str(request.get("item", "")),
                )
            elif operation == "complete":
                self._event(
                    "complete",
                    checkout_id=checkout_id,
                    identity=checkout["identity"],
                    lane=checkout["lane"],
                    owner_pid=pid,
                    owner_uid=uid,
                    input_sha256=str(request.get("input_sha256", "")),
                    primary=str(request.get("primary", "")),
                    secondary=str(request.get("secondary", "")),
                    task_kind=str(request.get("task_kind", "")),
                )
            elif operation == "release":
                self._event(
                    "released",
                    checkout_id=checkout_id,
                    identity=checkout["identity"],
                    lane=checkout["lane"],
                    width=checkout["width"],
                    owner_pid=pid,
                    work_units=checkout["work_units"],
                )
                del self.checkouts[checkout_id]
            else:
                return {"ok": False, "reason": "unknown_operation"}
            self.persist()
            return {"ok": True}


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        credentials = self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        pid, uid, _gid = struct.unpack("3i", credentials)
        line = self.rfile.readline(1024 * 1024)
        try:
            request = json.loads(line)
            response = self.server.ledger.handle(request, pid, uid)
        except Exception as error:
            response = {"ok": False, "reason": "request_error", "detail": type(error).__name__}
        self.wfile.write((json.dumps(response, sort_keys=True) + "\n").encode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--socket-gid", required=True, type=int)
    args = parser.parse_args()
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    ledger = SeatLedger(args.policy, args.state)
    server = ThreadingUnixServer(args.socket, Handler)
    server.ledger = ledger
    os.chown(args.socket, 0, args.socket_gid)
    os.chmod(args.socket, 0o660)
    stop = threading.Event()

    def shutdown(_signum, _frame):
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        if os.path.exists(args.socket):
            os.unlink(args.socket)


if __name__ == "__main__":
    main()
