#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import os
import pathlib
import pwd
import tempfile
import time
import urllib.request


def file_sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def proc_starttime(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]


def request_json(url, method="GET", payload=None, headers=None, timeout=3.0):
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    return json.loads(body) if body else {}


def render(manifest, generation):
    values = {
        "SERVICE_NAME": manifest["service_name"],
        "MODEL_API_BASE_URL": manifest["model_api_base_url"],
        "ROUTING_TABLE_SHA": manifest["routing_table_sha"],
        "GATEWAY_PROFILE": manifest["gateway_profile"],
        "RELEASE_REVISION": manifest["release_revision"],
        "ROUTE_SMOKE_KEY": manifest["route_smoke_key"],
        "RECONCILE_GENERATION": str(generation),
    }
    return "".join(f"{key}={values[key]}\n" for key in values), values


def atomic_publish(path, content, owner):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o664)
        if owner:
            pw = pwd.getpwnam(owner)
            os.chown(tmp_name, pw.pw_uid, pw.pw_gid)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def smoke_headers(values):
    timestamp = str(int(time.time()))
    message = f"{timestamp}|{values['MODEL_API_BASE_URL']}|{values['ROUTING_TABLE_SHA']}".encode("utf-8")
    signature = hmac.new(values["ROUTE_SMOKE_KEY"].encode("utf-8"), message, hashlib.sha256).hexdigest()
    return {"X-Smoke-Timestamp": timestamp, "X-Smoke-Signature": signature}


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def append_history(path, payload):
    with pathlib.Path(path).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest")
    source.add_argument("--manifest-fd", type=int)
    parser.add_argument("--env", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--history", required=True)
    parser.add_argument("--gateway-port", type=int, required=True)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--owner", default="agentb")
    args = parser.parse_args()

    if args.manifest_fd is not None:
        with os.fdopen(args.manifest_fd, "rb") as handle:
            manifest_bytes = handle.read()
    else:
        manifest_bytes = pathlib.Path(args.manifest).read_bytes()
    manifest = json.loads(manifest_bytes)
    manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()

    pid = os.getpid()
    starttime = proc_starttime(pid)
    generation = 0
    while True:
        started = time.time()
        status = {
            "pid": pid,
            "starttime": starttime,
            "generation": generation,
            "ok": False,
            "last_attempt": started,
        }
        try:
            generation += 1
            content, values = render(manifest, generation)
            atomic_publish(args.env, content, args.owner)
            reload_payload = request_json(
                f"http://127.0.0.1:{args.gateway_port}/reload",
                method="POST",
                payload={"env_file": args.env},
                timeout=3.0,
            )
            smoke_payload = request_json(
                f"http://127.0.0.1:{args.gateway_port}/v1/route-smoke",
                headers=smoke_headers(values),
                timeout=3.0,
            )
            active = smoke_payload.get("active", {})
            smoke_ok = (
                smoke_payload.get("ok") is True
                and active.get("MODEL_API_BASE_URL") == values["MODEL_API_BASE_URL"]
                and active.get("GATEWAY_PROFILE") == values["GATEWAY_PROFILE"]
            )
            stat = pathlib.Path(args.env).stat()
            status = {
                "pid": pid,
                "starttime": starttime,
                "generation": generation,
                "ok": smoke_ok and reload_payload.get("ok") is True,
                "smoke_ok": smoke_ok,
                "last_success": time.time() if smoke_ok else 0,
                "manifest_sha256": manifest_sha256,
                "env_inode": stat.st_ino,
                "env_sha256": hashlib.sha256(pathlib.Path(args.env).read_bytes()).hexdigest(),
                "active_profile": active.get("GATEWAY_PROFILE", ""),
                "active_base_url": active.get("MODEL_API_BASE_URL", ""),
                "routing_table_sha": active.get("ROUTING_TABLE_SHA", ""),
                "reloads": reload_payload.get("reloads"),
            }
        except Exception as exc:
            status.update(
                {
                    "generation": generation,
                    "ok": False,
                    "smoke_ok": False,
                    "error": f"{type(exc).__name__}:{exc}",
                }
            )
        atomic_json(args.status, status)
        append_history(args.history, {"time": time.time(), **status})
        delay = args.interval - (time.time() - started)
        if delay > 0:
            time.sleep(delay)


if __name__ == "__main__":
    main()
