#!/usr/bin/env python3
import argparse
import ctypes
import json
import os
import signal
import socket
import sys
import time


def set_process_name(name):
    try:
        ctypes.CDLL(None).prctl(15, name.encode("ascii")[:15], 0, 0, 0)
    except Exception:
        pass


def atomic_text(path, value):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(str(value) + "\n")
    os.replace(tmp, path)


def atomic_json(path, value):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def current_path_inode(path):
    try:
        return os.lstat(path).st_ino
    except FileNotFoundError:
        return None


class PolicyService:
    def __init__(self, args):
        self.args = args
        self.bundle = load_json(args.bundle)
        self.eval_count = 0
        self.last_policy_id = ""
        self.running = True
        self.listener = None
        self.path_inode = None

    def write_state(self):
        atomic_json(
            self.args.state_file,
            {
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "generation_token": self.args.generation_token,
                "eval_count": self.eval_count,
                "last_policy_id": self.last_policy_id,
                "updated_at": time.time(),
            },
        )

    def append_event(self, request, response):
        event = {
            "time": time.time(),
            "policy_id": self.last_policy_id,
            "decision": response.get("decision"),
            "rule_id": response.get("rule_id"),
            "eval_count": self.eval_count,
            "request": request,
        }
        with open(self.args.journal, "a", encoding="utf-8", buffering=1) as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")

    def evaluate(self, request):
        policy_id = str(request.get("policy_id", ""))
        rule = self.bundle.get("rules", {}).get(policy_id)
        self.eval_count += 1
        self.last_policy_id = policy_id
        if not rule:
            response = {
                "ok": False,
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "generation_token": self.args.generation_token,
                "policy_id": policy_id,
                "error": "unknown policy",
                "eval_count": self.eval_count,
            }
        else:
            response = {
                "ok": True,
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "generation_token": self.args.generation_token,
                "policy_id": policy_id,
                "decision": rule.get("decision"),
                "rule_id": rule.get("rule_id"),
                "reason": rule.get("reason"),
                "eval_count": self.eval_count,
            }
        self.write_state()
        self.append_event(request, response)
        return response

    def handle(self, payload):
        op = payload.get("op")
        if op == "health":
            return {
                "ok": True,
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "generation_token": self.args.generation_token,
                "eval_count": self.eval_count,
                "last_policy_id": self.last_policy_id,
            }
        if op == "version":
            return {
                "ok": True,
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "schema": "policy-rpc-v1",
                "generation_token": self.args.generation_token,
            }
        if op == "stats":
            return {
                "ok": True,
                "service": self.args.service_name,
                "policy_version": self.args.policy_version,
                "generation_token": self.args.generation_token,
                "eval_count": self.eval_count,
                "last_policy_id": self.last_policy_id,
            }
        if op == "evaluate":
            request = payload.get("request")
            if not isinstance(request, dict):
                return {"ok": False, "service": self.args.service_name, "error": "missing request"}
            return self.evaluate(request)
        return {"ok": False, "service": self.args.service_name, "error": "unsupported op"}

    def stop(self, _sig, _frame):
        self.running = False
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass

    def serve(self):
        os.makedirs(os.path.dirname(self.args.socket), exist_ok=True)
        os.makedirs(os.path.dirname(self.args.pid_file), exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener = listener
        listener.bind(self.args.socket)
        listener.listen(16)
        listener.settimeout(0.2)
        os.chmod(self.args.socket, 0o666)

        fd_inode = os.fstat(listener.fileno()).st_ino
        self.path_inode = os.lstat(self.args.socket).st_ino
        atomic_text(self.args.pid_file, os.getpid())
        atomic_text(self.args.fd_inode_file, fd_inode)
        atomic_text(self.args.path_inode_file, self.path_inode)
        atomic_text(self.args.generation_file, self.args.generation_token)
        self.write_state()
        print(
            "POLICY_ENGINE_READY pid=%d fd_inode=%s path_inode=%s"
            % (os.getpid(), fd_inode, self.path_inode),
            flush=True,
        )

        while self.running:
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.running:
                    raise
                break
            with conn:
                conn.settimeout(1.0)
                try:
                    raw = conn.recv(65536).decode("utf-8").strip()
                    payload = json.loads(raw)
                    response = self.handle(payload)
                except Exception as exc:
                    response = {"ok": False, "service": self.args.service_name, "error": str(exc)}
                conn.sendall((json.dumps(response, sort_keys=True) + "\n").encode("utf-8"))

    def cleanup(self):
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        if self.path_inode is not None and current_path_inode(self.args.socket) == self.path_inode:
            try:
                os.unlink(self.args.socket)
            except FileNotFoundError:
                pass
        for path in (
            self.args.pid_file,
            self.args.fd_inode_file,
            self.args.path_inode_file,
            self.args.generation_file,
        ):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--fd-inode-file", required=True)
    parser.add_argument("--path-inode-file", required=True)
    parser.add_argument("--generation-file", required=True)
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--policy-version", required=True)
    parser.add_argument("--generation-token", required=True)
    args = parser.parse_args()

    set_process_name("policy-engined")
    os.makedirs(os.path.dirname(args.state_file), exist_ok=True)
    os.makedirs(os.path.dirname(args.journal), exist_ok=True)
    service = PolicyService(args)
    signal.signal(signal.SIGTERM, service.stop)
    signal.signal(signal.SIGINT, service.stop)
    try:
        service.serve()
    finally:
        service.cleanup()


if __name__ == "__main__":
    main()

