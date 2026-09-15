#!/usr/bin/env python3
import argparse
import errno
import json
import os
import signal
import socket
import stat
import sys
import time


def atomic_json(path, value):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def call(socket_path, payload, timeout=1.0):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(socket_path)
        client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        return json.loads(client.recv(65536).decode("utf-8"))
    finally:
        client.close()


def wait_call(socket_path, payload, attempts=40, delay=0.1):
    last = None
    for _ in range(attempts):
        try:
            return call(socket_path, payload)
        except Exception as exc:
            last = exc
            time.sleep(delay)
    raise RuntimeError("socket RPC did not become ready: %s" % last)


class CandidateServer:
    def __init__(self, args):
        self.args = args
        self.bundle = load_json(args.bundle)
        self.listener = None
        self.path_inode = None
        self.running = True
        self.eval_count = 0
        self.last_policy_id = ""

    @property
    def service(self):
        return self.bundle.get("service", "candidate-policy-compat")

    @property
    def policy_version(self):
        return self.bundle.get("policy_version", "candidate-unknown")

    @property
    def generation_token(self):
        return self.bundle.get("generation_token", "candidate-generation")

    def handle(self, payload):
        op = payload.get("op")
        if op == "health":
            return {
                "ok": True,
                "service": self.service,
                "policy_version": self.policy_version,
                "generation_token": self.generation_token,
                "eval_count": self.eval_count,
                "last_policy_id": self.last_policy_id,
            }
        if op == "version":
            return {
                "ok": True,
                "service": self.service,
                "policy_version": self.policy_version,
                "schema": "policy-rpc-v1",
                "generation_token": self.generation_token,
            }
        if op == "evaluate":
            request = payload.get("request")
            if not isinstance(request, dict):
                return {"ok": False, "service": self.service, "error": "missing request"}
            policy_id = str(request.get("policy_id", ""))
            rule = self.bundle.get("rules", {}).get(policy_id)
            self.eval_count += 1
            self.last_policy_id = policy_id
            if not rule:
                return {
                    "ok": False,
                    "service": self.service,
                    "policy_version": self.policy_version,
                    "generation_token": self.generation_token,
                    "policy_id": policy_id,
                    "error": "unknown policy",
                    "eval_count": self.eval_count,
                }
            return {
                "ok": True,
                "service": self.service,
                "policy_version": self.policy_version,
                "generation_token": self.generation_token,
                "policy_id": policy_id,
                "decision": rule.get("decision"),
                "rule_id": rule.get("rule_id"),
                "reason": rule.get("reason"),
                "eval_count": self.eval_count,
            }
        if op == "stats":
            return {
                "ok": True,
                "service": self.service,
                "policy_version": self.policy_version,
                "eval_count": self.eval_count,
                "last_policy_id": self.last_policy_id,
            }
        return {"ok": False, "service": self.service, "error": "unsupported op"}

    def stop(self, _sig, _frame):
        self.running = False
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass

    def cleanup(self):
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        if self.path_inode is not None:
            try:
                current = os.lstat(self.args.socket).st_ino
            except FileNotFoundError:
                current = None
            if current == self.path_inode:
                try:
                    os.unlink(self.args.socket)
                except FileNotFoundError:
                    pass

    def serve(self):
        for path in (self.args.ready, self.args.error, self.args.state):
            if path:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
        os.makedirs(os.path.dirname(self.args.socket), exist_ok=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(self.args.socket)
        except OSError as exc:
            if self.args.error:
                os.makedirs(os.path.dirname(self.args.error), exist_ok=True)
                atomic_json(
                    self.args.error,
                    {
                        "ok": False,
                        "stage": "bind",
                        "socket": self.args.socket,
                        "errno": exc.errno,
                        "error": exc.strerror,
                        "service": self.service,
                    },
                )
            print("CANDIDATE_BIND_FAILED errno=%s socket=%s" % (exc.errno, self.args.socket), file=sys.stderr)
            return 98 if exc.errno == errno.EADDRINUSE else 1
        self.listener = listener
        listener.listen(16)
        listener.settimeout(0.2)
        os.chmod(self.args.socket, 0o666)
        fd_inode = os.fstat(listener.fileno()).st_ino
        self.path_inode = os.lstat(self.args.socket).st_ino
        ready = {
            "ok": True,
            "service": self.service,
            "policy_version": self.policy_version,
            "socket": self.args.socket,
            "pid": os.getpid(),
            "fd_inode": fd_inode,
            "path_inode": self.path_inode,
        }
        if self.args.ready:
            os.makedirs(os.path.dirname(self.args.ready), exist_ok=True)
            atomic_json(self.args.ready, ready)
        if self.args.state:
            os.makedirs(os.path.dirname(self.args.state), exist_ok=True)
            atomic_json(self.args.state, ready)
        print("CANDIDATE_READY pid=%d socket=%s" % (os.getpid(), self.args.socket), flush=True)
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
                    response = self.handle(json.loads(raw))
                except Exception as exc:
                    response = {"ok": False, "service": self.service, "error": str(exc)}
                conn.sendall((json.dumps(response, sort_keys=True) + "\n").encode("utf-8"))
        return 0


def command_serve(args):
    server = CandidateServer(args)
    signal.signal(signal.SIGTERM, server.stop)
    signal.signal(signal.SIGINT, server.stop)
    try:
        return server.serve()
    finally:
        server.cleanup()


def command_validate(args):
    request = load_json(args.request)
    ready = {}
    if args.ready and os.path.exists(args.ready):
        ready = load_json(args.ready)
    health = wait_call(args.socket, {"op": "health"})
    version = call(args.socket, {"op": "version"})
    evaluation = call(args.socket, {"op": "evaluate", "request": request})
    expected = {
        "service": "candidate-policy-compat",
        "policy_version": "candidate-2026.07",
        "decision": "allow",
        "rule_id": "ci-build-deploy",
    }
    ok = (
        stat.S_ISSOCK(os.lstat(args.socket).st_mode)
        and ready.get("service") == expected["service"]
        and health.get("service") == expected["service"]
        and version.get("policy_version") == expected["policy_version"]
        and evaluation.get("service") == expected["service"]
        and evaluation.get("policy_version") == expected["policy_version"]
        and evaluation.get("decision") == expected["decision"]
        and evaluation.get("rule_id") == expected["rule_id"]
    )
    if not ok:
        raise SystemExit("candidate policy validation failed")
    result = {
        "ok": True,
        "socket": args.socket,
        "ready": ready,
        "health": health,
        "version": version,
        "evaluation": evaluation,
        "request": request,
    }
    atomic_json(args.output, result)
    print("CANDIDATE_VALIDATED output=%s decision=%s" % (args.output, evaluation.get("decision")))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Candidate CI policy compatibility server")
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve")
    serve.add_argument("--socket", required=True)
    serve.add_argument("--bundle", required=True)
    serve.add_argument("--ready", default="/work/policy_engine_ready.json")
    serve.add_argument("--error", default="/work/policy_engine_error.json")
    serve.add_argument("--state", default="/work/policy_engine_candidate_state.json")
    serve.set_defaults(func=command_serve)

    validate = sub.add_parser("validate")
    validate.add_argument("--socket", required=True)
    validate.add_argument("--request", required=True)
    validate.add_argument("--output", required=True)
    validate.add_argument("--ready", default="/work/policy_engine_ready.json")
    validate.set_defaults(func=command_validate)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()

