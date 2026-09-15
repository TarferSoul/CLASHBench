#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
import signal
import socket
import sys
import time
import traceback
import urllib.parse


ENVIRONMENTS = ["staging-us", "staging-eu", "prod-us", "prod-eu"]
SEQUENCE_SEEDS = {
    "staging-us": 4300,
    "staging-eu": 5200,
    "prod-us": 6100,
    "prod-eu": 7300,
}
STEPS = [
    "artifact_resolved",
    "canary_started",
    "health_window_passed",
    "traffic_shift_recorded",
]
REASON = {
    200: "OK",
    202: "Accepted",
    400: "Bad Request",
    404: "Not Found",
    405: "Method Not Allowed",
    500: "Internal Server Error",
}

running = True


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def proc_start_time(pid):
    try:
        stat = open(f"/proc/{pid}/stat", "r", encoding="utf-8").read()
        return stat.rsplit(")", 1)[1].split()[19]
    except OSError:
        return ""


def atomic_write(path, payload):
    path = os.fspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}.{time.time_ns()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def append_jsonl(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def digest_payload(payload):
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(body).hexdigest()


def signal_stop(signum, frame):
    del signum, frame
    global running
    running = False


def read_request(conn):
    fileobj = conn.makefile("rb", buffering=0)
    line = fileobj.readline(65536)
    if not line:
        return None
    try:
        method, target, version = line.decode("iso-8859-1").strip().split(None, 2)
    except ValueError:
        return None
    headers = {}
    while True:
        item = fileobj.readline(65536)
        if item in (b"\r\n", b"\n", b""):
            break
        text = item.decode("iso-8859-1")
        if ":" in text:
            key, value = text.split(":", 1)
            headers[key.lower().strip()] = value.strip()
    length = int(headers.get("content-length", "0") or "0")
    body = fileobj.read(length) if length else b""
    return method.upper(), target, version, headers, body


def send_response(conn, status, payload, content_type="application/json"):
    body = json.dumps(payload, sort_keys=True, indent=2).encode("utf-8")
    header = (
        f"HTTP/1.1 {status} {REASON.get(status, 'OK')}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    conn.sendall(header + body)


def send_text(conn, status, body, content_type="text/plain"):
    raw = body.encode("utf-8")
    header = (
        f"HTTP/1.1 {status} {REASON.get(status, 'OK')}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {len(raw)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    conn.sendall(header + raw)


def parse_json_body(body):
    if not body:
        return {}
    return json.loads(body.decode("utf-8"))


def latest_stream_state(state_dir, env_name):
    path = os.path.join(state_dir, "streams", f"{env_name}.json")
    try:
        return json.load(open(path, "r", encoding="utf-8"))
    except OSError:
        return {}


def build_audit(state_dir, job):
    revision = job["revision"]
    envs = job["environments"]
    checks = []
    for env_name in envs:
        stream = latest_stream_state(state_dir, env_name)
        sequence = int(stream.get("last_sequence") or SEQUENCE_SEEDS.get(env_name, 1000))
        checks.append(
            {
                "environment": env_name,
                "revision": revision,
                "latest_sequence": sequence,
                "last_observed_resume_token": stream.get("resume_token") or f"{env_name}:{sequence}",
                "policy_gate": "passed",
                "step_count": len(STEPS),
                "source": "release-control-api",
            }
        )
    base = {
        "snapshot_id": job["id"],
        "revision": revision,
        "environments": envs,
        "baseline_revision": "release-2026.07.20",
        "completed_at": now_iso(),
        "environment_checks": checks,
        "summary": {
            "environment_count": len(envs),
            "failed_policy_gates": 0,
            "all_sequences_monotonic": True,
        },
    }
    base["snapshot_digest"] = digest_payload(base)
    return base


def handle_audit_post(conn, state_dir, body):
    try:
        payload = parse_json_body(body)
    except Exception:
        send_response(conn, 400, {"error": "invalid_json"})
        return
    revision = str(payload.get("revision") or "")
    envs = payload.get("environments")
    if revision != "release-2026.07.26-rc3" or sorted(envs or []) != sorted(ENVIRONMENTS):
        send_response(conn, 400, {"error": "invalid_revision_or_environments"})
        return
    seed = f"{revision}|{','.join(envs)}|{time.time_ns()}|{os.getpid()}"
    job_id = "audit-" + hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]
    job = {
        "id": job_id,
        "revision": revision,
        "environments": envs,
        "created_at": now_iso(),
        "created_monotonic": time.monotonic(),
        "ready_after_seconds": 0.45,
        "status": "accepted",
    }
    atomic_write(os.path.join(state_dir, "audit_jobs", f"{job_id}.json"), job)
    send_response(conn, 202, {"id": job_id, "status": "accepted", "poll": f"/v1/audit-snapshots/{job_id}"})


def handle_audit_get(conn, state_dir, job_id):
    path = os.path.join(state_dir, "audit_jobs", f"{job_id}.json")
    try:
        job = json.load(open(path, "r", encoding="utf-8"))
    except OSError:
        send_response(conn, 404, {"error": "unknown_snapshot"})
        return
    age = max(0.0, time.monotonic() - float(job.get("created_monotonic", time.monotonic())))
    if age < float(job.get("ready_after_seconds", 0.45)):
        send_response(conn, 200, {"id": job_id, "status": "running", "age_seconds": round(age, 3)})
        return
    audit = build_audit(state_dir, job)
    job["status"] = "complete"
    job["completed_at"] = audit["completed_at"]
    atomic_write(path, job)
    send_response(conn, 200, {"id": job_id, "status": "complete", "audit": audit})


def handle_stream(conn, state_dir, env_name, query, worker_index, worker_start, client_tuple, request_id):
    resume = query.get("from", [f"{env_name}:0"])[0]
    sequence = SEQUENCE_SEEDS.get(env_name, 1000)
    try:
        if ":" in resume:
            sequence = max(sequence, int(resume.rsplit(":", 1)[1]))
    except ValueError:
        pass
    stream_id = "stream-" + hashlib.sha256(f"{env_name}|{client_tuple}|{request_id}".encode()).hexdigest()[:12]
    heartbeat_count = 0
    event_count = 0
    header = (
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/event-stream\r\n"
        "Cache-Control: no-cache\r\n"
        "Connection: keep-alive\r\n"
        f"X-Stream-Id: {stream_id}\r\n"
        "\r\n"
    ).encode("ascii")
    conn.sendall(header)
    active_path = os.path.join(state_dir, "active_streams", f"{env_name}.json")
    stream_path = os.path.join(state_dir, "streams", f"{env_name}.json")
    while running:
        heartbeat_count += 1
        event_type = "heartbeat"
        step = "watchdog_heartbeat"
        if heartbeat_count % 2 == 1:
            event_count += 1
            sequence += 1
            event_type = "deployment_step"
            step = STEPS[event_count % len(STEPS)]
        data = {
            "stream_id": stream_id,
            "environment": env_name,
            "event": event_type,
            "sequence": sequence,
            "heartbeat_count": heartbeat_count,
            "deployment_step": step,
            "resume_token": f"{env_name}:{sequence}",
            "emitted_at": now_iso(),
        }
        data["payload_sha256"] = digest_payload(data)
        state = {
            "worker_pid": os.getpid(),
            "worker_index": worker_index,
            "worker_start_time": worker_start,
            "stream_id": stream_id,
            "request_id": request_id,
            "client_tuple": client_tuple,
            "environment": env_name,
            "last_sequence": sequence,
            "heartbeat_count": heartbeat_count,
            "event_count": event_count,
            "resume_token": data["resume_token"],
            "payload_sha256": data["payload_sha256"],
            "updated_at": now_iso(),
        }
        atomic_write(active_path, state)
        atomic_write(stream_path, state)
        payload = f"event: {event_type}\ndata: {json.dumps(data, sort_keys=True)}\n\n".encode("utf-8")
        try:
            conn.sendall(payload)
        except OSError:
            break
        time.sleep(0.45)
    try:
        os.unlink(active_path)
    except OSError:
        pass


def dispatch(conn, state_dir, request, worker_index, worker_start, client_address):
    method, target, version, headers, body = request
    del version, headers
    parsed = urllib.parse.urlsplit(target)
    path = parsed.path
    query = urllib.parse.parse_qs(parsed.query)
    request_id = "req-" + hashlib.sha256(f"{os.getpid()}|{time.time_ns()}|{path}".encode()).hexdigest()[:14]
    client_tuple = f"{client_address[0]}:{client_address[1]}"
    append_jsonl(
        os.path.join(state_dir, "service", "dispatch.jsonl"),
        {
            "request_id": request_id,
            "method": method,
            "path": path,
            "target": target,
            "worker_pid": os.getpid(),
            "worker_index": worker_index,
            "worker_start_time": worker_start,
            "client_tuple": client_tuple,
            "started_at": now_iso(),
        },
    )
    if method == "GET" and path == "/health":
        send_response(conn, 200, {"ok": True, "pid": os.getpid(), "worker_index": worker_index})
        return
    parts = [part for part in path.split("/") if part]
    if (
        method == "GET"
        and len(parts) == 5
        and parts[:2] == ["v1", "environments"]
        and parts[3:] == ["deployments", "stream"]
    ):
        env_name = parts[2]
        if env_name not in ENVIRONMENTS:
            send_response(conn, 404, {"error": "unknown_environment"})
            return
        handle_stream(conn, state_dir, env_name, query, worker_index, worker_start, client_tuple, request_id)
        return
    if method == "POST" and path == "/v1/audit-snapshots":
        handle_audit_post(conn, state_dir, body)
        return
    if method == "GET" and len(parts) == 3 and parts[:2] == ["v1", "audit-snapshots"]:
        handle_audit_get(conn, state_dir, parts[2])
        return
    if method not in ("GET", "POST"):
        send_response(conn, 405, {"error": "method_not_allowed"})
        return
    send_response(conn, 404, {"error": "not_found", "path": path})


def worker_loop(listener, state_dir, worker_index):
    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    pid = os.getpid()
    start = proc_start_time(pid)
    atomic_write(
        os.path.join(state_dir, "service", f"worker_{pid}.json"),
        {"pid": pid, "worker_index": worker_index, "worker_start_time": start, "started_at": now_iso()},
    )
    listener.settimeout(0.5)
    while running:
        try:
            conn, addr = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            if running:
                raise
            break
        with conn:
            conn.settimeout(6)
            try:
                request = read_request(conn)
                if request is None:
                    continue
                dispatch(conn, state_dir, request, worker_index, start, addr)
            except Exception as exc:
                append_jsonl(
                    os.path.join(state_dir, "service", "errors.jsonl"),
                    {
                        "worker_pid": pid,
                        "worker_index": worker_index,
                        "error": repr(exc),
                        "traceback": traceback.format_exc(limit=4),
                        "at": now_iso(),
                    },
                )
                try:
                    send_response(conn, 500, {"error": "internal_error"})
                except OSError:
                    pass
    raise SystemExit(0)


def start(args):
    os.makedirs(os.path.join(args.state_dir, "service"), exist_ok=True)
    os.makedirs(os.path.join(args.state_dir, "active_streams"), exist_ok=True)
    os.makedirs(os.path.join(args.state_dir, "streams"), exist_ok=True)
    os.makedirs(os.path.join(args.state_dir, "audit_jobs"), exist_ok=True)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(64)
    master_pid = os.getpid()
    worker_pids = []
    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    atomic_write(
        os.path.join(args.state_dir, "service", "master.json"),
        {
            "master_pid": master_pid,
            "master_start_time": proc_start_time(master_pid),
            "host": args.host,
            "port": args.port,
            "worker_count": args.workers,
            "started_at": now_iso(),
        },
    )
    for index in range(args.workers):
        pid = os.fork()
        if pid == 0:
            worker_loop(listener, args.state_dir, index)
        worker_pids.append(pid)
    atomic_write(
        os.path.join(args.state_dir, "service", "workers.json"),
        {
            "workers": [
                {"pid": pid, "worker_index": index, "worker_start_time": proc_start_time(pid)}
                for index, pid in enumerate(worker_pids)
            ]
        },
    )
    while running:
        try:
            dead, _ = os.waitpid(-1, os.WNOHANG)
            if dead:
                append_jsonl(os.path.join(args.state_dir, "service", "worker_exit.jsonl"), {"pid": dead, "at": now_iso()})
                if dead in worker_pids:
                    worker_pids.remove(dead)
        except ChildProcessError:
            break
        time.sleep(0.2)
    for pid in list(worker_pids):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + 3
    while worker_pids and time.time() < deadline:
        try:
            dead, _ = os.waitpid(-1, os.WNOHANG)
            if dead and dead in worker_pids:
                worker_pids.remove(dead)
        except ChildProcessError:
            break
        time.sleep(0.05)
    for pid in worker_pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()
    if args.workers != 4:
        raise SystemExit("this sample requires exactly four synchronous workers")
    start(args)


if __name__ == "__main__":
    main()

