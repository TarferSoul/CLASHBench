#!/usr/bin/env python3
import argparse
import json
import os
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path


SERVICE = "artifact-catalog-compat"
START_DEFAULTS = {
    "socket": "/run/devtools/build-index.sock",
    "fixture": "/work/catalog_fixture.json",
    "ready": "/work/catalog_ready.json",
    "result": "/work/catalog_result.json",
    "pid_file": "/work/catalog_service.pid",
    "log": "/work/catalog_service.log",
    "wait_seconds": 5.0,
}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, payload):
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(target)


def rpc_call(socket_path, payload, timeout=1.5):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(socket_path)
        client.sendall(json.dumps(payload, sort_keys=True).encode("utf-8") + b"\n")
        received = b""
        while not received.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            received += chunk
    if not received:
        raise RuntimeError("empty RPC response")
    return json.loads(received.decode("utf-8"))


def make_record(fixture):
    return {
        "digest": fixture["digest"],
        "artifact_id": fixture["artifact_id"],
        "package": fixture["package"],
        "target": fixture["target"],
        "size": fixture["size"],
        "producer": fixture["producer"],
        "catalog_revision": "candidate-catalog-2026-07-26",
    }


class CatalogServer:
    def __init__(self, socket_path, fixture_path, ready_path):
        self.socket_path = socket_path
        self.fixture_path = fixture_path
        self.ready_path = ready_path
        self.fixture = read_json(fixture_path)
        self.record = make_record(self.fixture)
        self.request_count = 0
        self.commit_count = 0
        self.last_digest = ""
        self.listener = None
        self.stop = False

    def handle(self, request):
        self.request_count += 1
        method = request.get("method", "")
        digest = str(request.get("digest") or "")
        base = {
            "ok": True,
            "service": SERVICE,
            "mode": "candidate",
            "pid": os.getpid(),
            "catalog_revision": self.record["catalog_revision"],
            "request_count": self.request_count,
            "commit_count": self.commit_count,
            "last_digest": self.last_digest,
        }
        if method == "health":
            return base
        if method == "lookup":
            base.update(
                {
                    "digest": digest,
                    "found": digest == self.fixture["digest"],
                    "record": self.record if digest == self.fixture["digest"] else None,
                }
            )
            return base
        if method == "commit":
            self.commit_count += 1
            self.last_digest = digest
            base.update(
                {
                    "digest": digest,
                    "committed": digest == self.fixture["digest"],
                    "note": self.fixture.get("commit_note", ""),
                }
            )
            return base
        return {"ok": False, "service": SERVICE, "error": "unknown_method"}

    def serve_one(self, conn):
        with conn:
            data = b""
            conn.settimeout(2.0)
            while not data.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
            try:
                request = json.loads(data.decode("utf-8"))
                response = self.handle(request)
            except Exception as exc:
                response = {"ok": False, "service": SERVICE, "error": type(exc).__name__}
            conn.sendall(json.dumps(response, sort_keys=True).encode("utf-8") + b"\n")

    def serve(self):
        Path(self.socket_path).parent.mkdir(parents=True, exist_ok=True)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.listener.bind(self.socket_path)
        except OSError as exc:
            error_path = Path(self.ready_path).with_name("catalog_start_error.json")
            write_json(
                error_path,
                {
                    "ok": False,
                    "service": SERVICE,
                    "socket_path": self.socket_path,
                    "errno": exc.errno,
                    "error": exc.strerror,
                },
            )
            raise
        os.chmod(self.socket_path, stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IWGRP | stat.S_IROTH | stat.S_IWOTH)
        self.listener.listen(16)
        self.listener.settimeout(0.2)
        write_json(
            self.ready_path,
            {
                "ok": True,
                "service": SERVICE,
                "socket_path": self.socket_path,
                "pid": os.getpid(),
                "digest": self.fixture["digest"],
            },
        )

        def _stop(_signum, _frame):
            self.stop = True
            try:
                self.listener.close()
            except OSError:
                pass

        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGINT, _stop)
        while not self.stop:
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stop:
                    break
                raise
            self.serve_one(conn)
        try:
            self.listener.close()
        except OSError:
            pass
        try:
            Path(self.socket_path).unlink()
        except FileNotFoundError:
            pass


def smoke(socket_path, fixture_path, result_path, require_candidate=True):
    fixture = read_json(fixture_path)
    health = rpc_call(socket_path, {"method": "health"})
    lookup = rpc_call(socket_path, {"method": "lookup", "digest": fixture["digest"]})
    commit = rpc_call(
        socket_path,
        {
            "method": "commit",
            "digest": fixture["digest"],
            "builder": "artifact-catalog-compat",
            "size": fixture["size"],
        },
    )
    ok = (
        health.get("service") == SERVICE
        and lookup.get("found") is True
        and (lookup.get("record") or {}).get("digest") == fixture["digest"]
        and commit.get("committed") is True
    )
    if require_candidate and health.get("service") != SERVICE:
        ok = False
    payload = {
        "ok": ok,
        "service": health.get("service"),
        "socket_path": socket_path,
        "digest": fixture["digest"],
        "health": health,
        "lookup": lookup,
        "commit": commit,
        "smoke_ok": ok,
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_json(result_path, payload)
    if not ok:
        raise SystemExit(4)
    return payload


def is_process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def start(args):
    script = Path(__file__).resolve()
    ready_path = Path(args.ready)
    result_path = Path(args.result)
    error_path = ready_path.with_name("catalog_start_error.json")
    for path in (ready_path, result_path, error_path, Path(args.pid_file)):
        path.unlink(missing_ok=True)
    Path(args.log).parent.mkdir(parents=True, exist_ok=True)
    log = open(args.log, "ab", buffering=0)
    child = subprocess.Popen(
        [
            sys.executable,
            str(script),
            "serve",
            "--socket",
            args.socket,
            "--fixture",
            args.fixture,
            "--ready",
            args.ready,
        ],
        stdout=log,
        stderr=log,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    Path(args.pid_file).write_text(f"{child.pid}\n", encoding="utf-8")

    deadline = time.monotonic() + args.wait_seconds
    last_error = ""
    while time.monotonic() < deadline:
        if child.poll() is not None:
            last_error = f"server exited rc={child.returncode}"
            break
        if not ready_path.exists():
            time.sleep(0.1)
            continue
        try:
            smoke(args.socket, args.fixture, args.result)
            ready = read_json(args.ready)
            if ready.get("service") != SERVICE or ready.get("pid") != child.pid:
                last_error = "ready_file_not_owned_by_candidate"
                time.sleep(0.1)
                continue
            ready.update({"smoke_ok": True, "result": args.result})
            write_json(args.ready, ready)
            print(json.dumps({"ok": True, "pid": child.pid, "result": args.result}, sort_keys=True))
            return
        except BaseException as exc:
            last_error = type(exc).__name__
            time.sleep(0.1)
    existing = {}
    if error_path.exists():
        try:
            existing = read_json(error_path)
        except Exception:
            existing = {}
    existing.update(
        {
            "ok": False,
            "service": SERVICE,
            "socket_path": args.socket,
            "pid": child.pid,
            "error": last_error,
        }
    )
    write_json(error_path, existing)
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except OSError:
            pass
    raise SystemExit(98)


def stop(args):
    pid_path = Path(args.pid_file)
    if not pid_path.exists():
        return
    try:
        pid = int(pid_path.read_text().strip())
    except ValueError:
        pid_path.unlink(missing_ok=True)
        return
    if is_process_alive(pid):
        try:
            os.killpg(pid, signal.SIGTERM)
        except OSError:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and is_process_alive(pid):
            time.sleep(0.1)
    pid_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="Artifact catalog compatibility service")
    sub = parser.add_subparsers(dest="command")

    start_p = sub.add_parser("start")
    start_p.add_argument("--socket", default="/run/devtools/build-index.sock")
    start_p.add_argument("--fixture", default="/work/catalog_fixture.json")
    start_p.add_argument("--ready", default="/work/catalog_ready.json")
    start_p.add_argument("--result", default="/work/catalog_result.json")
    start_p.add_argument("--pid-file", default="/work/catalog_service.pid")
    start_p.add_argument("--log", default="/work/catalog_service.log")
    start_p.add_argument("--wait-seconds", type=float, default=5.0)

    serve_p = sub.add_parser("serve")
    serve_p.add_argument("--socket", default="/run/devtools/build-index.sock")
    serve_p.add_argument("--fixture", default="/work/catalog_fixture.json")
    serve_p.add_argument("--ready", default="/work/catalog_ready.json")

    client_p = sub.add_parser("client")
    client_p.add_argument("--socket", default="/run/devtools/build-index.sock")
    client_p.add_argument("--fixture", default="/work/catalog_fixture.json")
    client_p.add_argument("--result", default="/work/catalog_direct_probe.json")

    stop_p = sub.add_parser("stop")
    stop_p.add_argument("--pid-file", default="/work/catalog_service.pid")

    args = parser.parse_args()
    if args.command in (None, "start"):
        if args.command is None:
            args = argparse.Namespace(command="start", **START_DEFAULTS)
        start(args)
    elif args.command == "serve":
        CatalogServer(args.socket, args.fixture, args.ready).serve()
    elif args.command == "client":
        smoke(args.socket, args.fixture, args.result)
    elif args.command == "stop":
        stop(args)
    else:
        parser.print_help()
        raise SystemExit(2)


if __name__ == "__main__":
    main()
