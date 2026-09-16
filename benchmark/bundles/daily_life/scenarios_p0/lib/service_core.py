#!/usr/bin/env python3
"""Shared transport and persistence core for independently designed scenarios."""

import argparse
import copy
import json
import os
import signal
import socket
import struct


class ScenarioCore:
    def __init__(self, fixture_path, state_path):
        self.fixture_path = fixture_path
        self.state_path = state_path
        with open(fixture_path, encoding="utf-8") as handle:
            self.fixture = json.load(handle)
        if os.path.exists(state_path):
            with open(state_path, encoding="utf-8") as handle:
                self.state = json.load(handle)
        else:
            self.reset("default")

    def save(self):
        temporary = self.state_path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(self.state, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.state_path)

    def reset(self, scenario):
        scenarios = self.fixture.get("scenarios", {})
        if scenario not in scenarios:
            raise ValueError(f"unknown scenario: {scenario}")
        self.state = copy.deepcopy(scenarios[scenario])
        self.state.setdefault("audit", [])
        self.save()

    def audit(self, actor_uid, action, target, before=None, after=None, reason="", metadata=None):
        record = {
            "seq": len(self.state.setdefault("audit", [])) + 1,
            "actor_uid": actor_uid,
            "action": action,
            "target": target,
            "reason": reason,
            "before": copy.deepcopy(before),
            "after": copy.deepcopy(after),
        }
        if metadata is not None:
            record["metadata"] = copy.deepcopy(metadata)
        self.state["audit"].append(record)

    @staticmethod
    def require_root(peer_uid):
        if peer_uid != 0:
            raise PermissionError("administrator operation requires uid 0")

    def dispatch(self, request, peer_uid):
        op = request.get("op")
        if op == "ping":
            return {"ok": True, "service": self.fixture.get("service_name", "everyday-service")}
        if op == "admin_reset":
            self.require_root(peer_uid)
            self.reset(str(request.get("scenario", "default")))
            return {"ok": True, "scenario": request.get("scenario", "default")}
        if op == "admin_snapshot":
            self.require_root(peer_uid)
            return {"ok": True, "state": self.state}
        response = self.handle(request, peer_uid)
        if response is None:
            return {"ok": False, "error": "unknown_operation"}
        return response

    def handle(self, request, peer_uid):
        raise NotImplementedError


def serve(service_class):
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--socket-gid", type=int, required=True)
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.socket), exist_ok=True)
    os.makedirs(os.path.dirname(args.state), exist_ok=True)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    service = service_class(args.fixture, args.state)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(args.socket)
    os.chown(args.socket, 0, args.socket_gid)
    os.chmod(args.socket, 0o660)
    server.listen(16)
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True
        server.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopping:
        try:
            connection, _ = server.accept()
        except OSError:
            break
        with connection:
            try:
                credentials = connection.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
                )
                _pid, peer_uid, _peer_gid = struct.unpack("3i", credentials)
                raw = b""
                while not raw.endswith(b"\n") and len(raw) < 1024 * 1024:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    raw += chunk
                response = service.dispatch(json.loads(raw.decode()), peer_uid)
            except Exception as error:
                response = {"ok": False, "error": type(error).__name__, "detail": str(error)}
            connection.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode())
    if os.path.exists(args.socket):
        os.unlink(args.socket)

