#!/usr/bin/env python3
"""Fenced multi-phase release client for ml-serving-prod."""

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

APP = pathlib.Path("/work/ml-serving-prod")
LEASE = APP / ".release" / "locks" / "ml-serving-prod.environment.lock"
STATE = APP / ".release" / "coordinator" / "active-release.json"
PID_FILE = APP / ".release" / "coordinator" / "active-release.pid"
HANDOFF_AUDIT = APP / ".release" / "audit" / "handoffs.jsonl"
CLIENT_AUDIT = APP / ".release" / "audit" / "release-client.jsonl"


def now_ns():
    return time.time_ns()


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def append_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def open_lock(blocking):
    handle = LEASE.open("a+")
    flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
    try:
        fcntl.flock(handle.fileno(), flags)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def descriptor(path, component):
    value = json.loads(pathlib.Path(path).read_text())
    required = {"component", "version", "digest", "signature", "compatibility_epoch"}
    if not required.issubset(value) or value["component"] != component:
        raise ValueError("descriptor_invalid")
    if not value["digest"].startswith("sha256:") or not value["signature"].startswith("ml-serving-release-signature-"):
        raise ValueError("signature_or_digest_invalid")
    return value


def phase_worker(args):
    started = now_ns()
    # Bounded CPU and filesystem work model signature/schema verification,
    # instance application, cache checks, and health sampling.
    checksum = hashlib.sha256()
    deadline = time.monotonic() + args.duration
    iterations = 0
    while time.monotonic() < deadline:
        checksum.update(f"{args.release_id}:{args.phase}:{args.sequence}:{iterations}".encode())
        iterations += 1
        time.sleep(0.015)
    atomic_json(args.result, {
        "release_id": args.release_id,
        "phase": args.phase,
        "handoff_seq": args.sequence,
        "worker_pid": os.getpid(),
        "health": "passed",
        "work_checksum": checksum.hexdigest(),
        "iterations": iterations,
        "started_ns": started,
        "finished_ns": now_ns(),
    })
    return 0


def incumbent(args):
    artifact = descriptor(args.artifact, "model-gateway")
    lease = open_lock(blocking=True)
    release_id = args.release_id
    token = int(args.fencing_token)
    receipts = APP / "components" / "model-gateway" / "stage-receipts"
    receipts.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(f"{os.getpid()}\n")
    running = True
    active_child = None

    def request_stop(_signum, _frame):
        nonlocal running
        running = False
        if active_child is not None and active_child.poll() is None:
            active_child.terminate()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    phases = [
        "verify_signature",
        "canary_proxy_node_1",
        "cache_coherency_probe",
        "rollout_proxy_nodes_2_4",
        "artifact_download_health",
        "commit_guard_validation",
    ]
    handoff_seq = 0
    previous_worker = 0
    previous_hash = "GENESIS"
    started_ns = now_ns()
    cycle = 0
    while running:
        for phase in phases:
            if not running:
                break
            handoff_seq += 1
            result = receipts / f"stage-{handoff_seq:06d}.json"
            command = [
                sys.executable, str(pathlib.Path(__file__).resolve()), "phase-worker",
                "--phase", phase, "--release-id", release_id,
                "--sequence", str(handoff_seq), "--duration", str(args.worker_seconds),
                "--result", str(result),
            ]
            active_child = subprocess.Popen(command)
            authority = active_child.pid
            succession_material = f"{previous_hash}|{release_id}|{token}|{handoff_seq}|{previous_worker}|{authority}|{phase}"
            handoff_hash = hashlib.sha256(succession_material.encode()).hexdigest()
            handoff = {
                "release_id": release_id,
                "fencing_token": token,
                "handoff_seq": handoff_seq,
                "from_worker_pid": previous_worker,
                "to_worker_pid": authority,
                "phase": phase,
                "previous_handoff_hash": previous_hash,
                "handoff_hash": handoff_hash,
                "protocol": "atomic_replace_sha256_succession_v1",
                "committed_ns": now_ns(),
            }
            state = {
                **handoff,
                "pid": os.getpid(),
                "supervisor_pid": os.getpid(),
                "started_ns": started_ns,
                "active_worker_pid": authority,
                "component": "model-gateway",
                "version": artifact["version"],
                "digest": artifact["digest"],
                "environment": "ml-serving-prod",
                "environment_inode": LEASE.stat().st_ino,
                "health": "passed",
                "cycle": cycle,
                "heartbeat_ns": now_ns(),
            }
            # Durably append the succession record, then expose exactly that
            # signed transfer with one atomic authoritative state replacement.
            append_json(HANDOFF_AUDIT, handoff)
            atomic_json(STATE, state)
            while active_child.poll() is None and running:
                time.sleep(0.02)
            if not running and active_child.poll() is None:
                active_child.terminate()
            try:
                worker_rc = active_child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                active_child.kill()
                worker_rc = active_child.wait()
            if running and worker_rc != 0:
                raise RuntimeError(f"phase_worker_failed:{phase}:{worker_rc}")
            previous_worker = authority
            previous_hash = handoff_hash
            active_child = None
        cycle += 1
    append_json(CLIENT_AUDIT, {"event": "incumbent_release", "pid": os.getpid(), "release_id": release_id, "fencing_token": token, "handoff_seq": handoff_seq, "time_ns": now_ns()})
    fcntl.flock(lease.fileno(), fcntl.LOCK_UN)
    lease.close()
    return 0


def rollback(args):
    if args.environment != "ml-serving-prod":
        print(json.dumps({"result": "unsupported_environment"}))
        return 64
    artifact = descriptor(args.artifact, "policy-engine")
    lease = open_lock(blocking=False)
    if lease is None:
        append_json(CLIENT_AUDIT, {"event": "environment_busy", "pid": os.getpid(), "environment": args.environment, "operation": "rollback", "time_ns": now_ns()})
        print(json.dumps({"result": "environment_busy", "busy_key": "ml-serving-prod.environment.lock", "mutation_started": False}, sort_keys=True))
        return 75
    append_json(CLIENT_AUDIT, {"event": "environment_acquired", "pid": os.getpid(), "environment": args.environment, "operation": "rollback", "inode": LEASE.stat().st_ino, "time_ns": now_ns()})
    time.sleep(args.hold_seconds)
    target = APP / "components" / "policy-engine" / "current.json"
    target_payload = {
        "component": "policy-engine",
        "operation": "rollback",
        "version": artifact["version"],
        "digest": artifact["digest"],
        "compatibility_epoch": artifact["compatibility_epoch"],
        "health": "passed",
        "publisher_pid": os.getpid(),
        "committed_ns": now_ns(),
    }
    atomic_json(target, target_payload)
    receipt = {
        **target_payload,
        "environment": args.environment,
        "environment_lease": str(LEASE),
        "result": "rolled_back",
        "health_probe": "model-route-and-policy-lookup",
    }
    atomic_json(args.receipt, receipt)
    append_json(CLIENT_AUDIT, {"event": "rollback_committed", "pid": os.getpid(), "environment": args.environment, "operation": "rollback", "version": artifact["version"], "digest": artifact["digest"], "time_ns": now_ns()})
    fcntl.flock(lease.fileno(), fcntl.LOCK_UN)
    lease.close()
    print(json.dumps({"result": "rolled_back", "version": artifact["version"], "receipt": args.receipt}, sort_keys=True))
    return 0


def parser():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="command", required=True)
    q = sub.add_parser("rollback")
    q.add_argument("--environment", required=True)
    q.add_argument("--artifact", required=True)
    q.add_argument("--receipt", required=True)
    q.add_argument("--hold-seconds", type=float, default=0.8)
    q.set_defaults(func=rollback)
    q = sub.add_parser("incumbent")
    q.add_argument("--artifact", required=True)
    q.add_argument("--release-id", required=True)
    q.add_argument("--fencing-token", required=True, type=int)
    q.add_argument("--worker-seconds", type=float, default=0.42)
    q.set_defaults(func=incumbent)
    q = sub.add_parser("phase-worker")
    q.add_argument("--phase", required=True)
    q.add_argument("--release-id", required=True)
    q.add_argument("--sequence", required=True, type=int)
    q.add_argument("--duration", required=True, type=float)
    q.add_argument("--result", required=True)
    q.set_defaults(func=phase_worker)
    return p


if __name__ == "__main__":
    options = parser().parse_args()
    try:
        raise SystemExit(options.func(options))
    except Exception as exc:
        print(json.dumps({"result": "release_error", "detail": f"{type(exc).__name__}:{exc}"}, sort_keys=True), file=sys.stderr)
        raise
