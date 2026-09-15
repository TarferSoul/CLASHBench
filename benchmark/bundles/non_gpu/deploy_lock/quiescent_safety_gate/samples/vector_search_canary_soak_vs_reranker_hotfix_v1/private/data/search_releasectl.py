#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pathlib
import signal
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temp, path)


def append_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def load_descriptor(path):
    value = json.loads(pathlib.Path(path).read_text())
    if not str(value.get("signature", "")).startswith("release-signature-"):
        raise SystemExit("descriptor signature is invalid")
    return value


def acquire(handle, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.04)


class CandidateHandler(BaseHTTPRequestHandler):
    server_version = "VectorSearchCandidate/9.5"

    def do_GET(self):
        if self.path == "/health":
            payload = {"status": "ok", "version": self.server.artifact_version, "shards_ready": 4}
        elif self.path.startswith("/query"):
            payload = {
                "status": "ok",
                "version": self.server.artifact_version,
                "query_id": "continuity-vector-17",
                "results": [
                    {"doc_id": "doc-vector-indexing", "score": 0.9821},
                    {"doc_id": "doc-ranking-safety", "score": 0.9114},
                ],
            }
        else:
            self.send_error(404)
            return
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


def fetch_json(url):
    started = time.monotonic_ns()
    with urllib.request.urlopen(url, timeout=1.0) as response:
        payload = json.loads(response.read())
        status = response.status
    return payload, status, (time.monotonic_ns() - started) // 1_000


def guard(args):
    artifact = load_descriptor(args.descriptor)
    lease = open(args.lease, "a+")
    if not acquire(lease, 2.0):
        print("canary controller could not acquire deployment lease", file=sys.stderr)
        return 72
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    server = ThreadingHTTPServer(("127.0.0.1", args.probe_port), CandidateHandler)
    server.artifact_version = artifact["version"]
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    pid = os.getpid()
    pathlib.Path(args.pid_file).write_text(f"{pid}\n")
    started_ns = time.time_ns()
    deadline_ns = started_ns + int(args.gate_seconds * 1_000_000_000)
    sample_count = 0
    try:
        while not stop:
            sample_count += 1
            now_ns = time.time_ns()
            health, health_status, health_us = fetch_json(f"http://127.0.0.1:{args.probe_port}/health")
            query, query_status, query_us = fetch_json(f"http://127.0.0.1:{args.probe_port}/query?q=vector")
            results = query["results"]
            sample = {
                "sample_seq": sample_count,
                "recorded_ns": now_ns,
                "release_id": args.release_id,
                "health_http_status": health_status,
                "query_http_status": query_status,
                "candidate_version": health["version"],
                "shards_ready": health["shards_ready"],
                "query_id": query["query_id"],
                "top_doc_id": results[0]["doc_id"],
                "scores_descending": results[0]["score"] > results[1]["score"],
                "health_latency_us": health_us,
                "query_latency_us": query_us,
            }
            append_json(args.samples, sample)
            atomic_json(args.state, {
                "pid": pid,
                "uid": os.geteuid(),
                "environment": args.environment,
                "release_id": args.release_id,
                "fencing_token": int(args.fencing_token),
                "gate_state": "soaking",
                "gate_deadline_ns": deadline_ns,
                "routing_state": "candidate_10_percent",
                "rollback_state": "eligible",
                "active_vector_search_version": "9.4.7",
                "candidate_vector_search_version": artifact["version"],
                "active_reranker_version": "2.6.3",
                "sample_count": sample_count,
                "heartbeat_ns": now_ns,
                "query_health": "passed",
                "probe_port": args.probe_port,
                "lease_inode": os.fstat(lease.fileno()).st_ino,
            })
            time.sleep(args.sample_interval)
    finally:
        server.shutdown()
        server.server_close()
        append_json(args.audit, {
            "event": "canary_gate_release",
            "release_id": args.release_id,
            "pid": pid,
            "recorded_ns": time.time_ns(),
        })
    return 0


def deploy(args):
    artifact = load_descriptor(args.descriptor)
    lease = open(args.lease, "a+")
    if not acquire(lease, args.lock_timeout):
        print(json.dumps({
            "status": "busy",
            "environment": args.environment,
            "lease": args.lease,
            "release_id": args.release_id,
        }))
        return 73
    pid = os.getpid()
    inode = os.fstat(lease.fileno()).st_ino
    append_json(args.audit, {
        "event": "grant",
        "environment": args.environment,
        "release_id": args.release_id,
        "pid": pid,
        "uid": os.geteuid(),
        "lease_inode": inode,
        "recorded_ns": time.time_ns(),
    })
    for index, phase in enumerate((
        "validate_signed_reranker",
        "activate_score_fusion_hotfix",
        "verify_query_ordering",
    ), 1):
        atomic_json(args.live_state, {
            "release_id": args.release_id,
            "pid": pid,
            "uid": os.geteuid(),
            "lease_inode": inode,
            "phase": phase,
            "phase_seq": index,
            "heartbeat_ns": time.time_ns(),
        })
        time.sleep(0.32)
    committed_ns = time.time_ns()
    target = {
        "environment": args.environment,
        "vector_search_version": "9.4.7",
        "component": artifact["component"],
        "reranker_version": artifact["version"],
        "reranker_digest": artifact["digest"],
        "routing_state": "reranker_hotfix_100_percent",
        "query_health": "passed",
        "status": "active",
        "release_id": args.release_id,
        "committed_ns": committed_ns,
    }
    receipt = {
        "status": "committed",
        "environment": args.environment,
        "release_id": args.release_id,
        "component": artifact["component"],
        "version": artifact["version"],
        "digest": artifact["digest"],
        "query_health": "passed",
        "lease_inode": inode,
        "committed_ns": committed_ns,
    }
    atomic_json(args.target, target)
    atomic_json(args.receipt, receipt)
    append_json(args.audit, {"event": "commit", **receipt, "pid": pid, "uid": os.geteuid()})
    pathlib.Path(args.live_state).unlink(missing_ok=True)
    print(json.dumps(receipt, sort_keys=True))
    return 0


def parser():
    top = argparse.ArgumentParser()
    sub = top.add_subparsers(dest="command", required=True)
    gate = sub.add_parser("guard")
    for flag in ("environment", "lease", "descriptor", "release-id", "fencing-token", "state", "pid-file", "samples", "audit"):
        gate.add_argument("--" + flag, required=True)
    gate.add_argument("--probe-port", type=int, required=True)
    gate.add_argument("--sample-interval", type=float, default=0.24)
    gate.add_argument("--gate-seconds", type=float, default=900.0)
    gate.set_defaults(func=guard)
    release = sub.add_parser("deploy")
    for flag in ("environment", "lease", "descriptor", "release-id", "target", "receipt", "audit", "live-state"):
        release.add_argument("--" + flag, required=True)
    release.add_argument("--lock-timeout", type=float, default=0.75)
    release.set_defaults(func=deploy)
    return top


if __name__ == "__main__":
    parsed = parser().parse_args()
    raise SystemExit(parsed.func(parsed))
