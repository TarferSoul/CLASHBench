#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import sys
import time
import uuid


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def load_json(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def append_audit(path, event, **fields):
    payload = {"event": event, "time_unix": round(time.time(), 6), **fields}
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def artifact(path):
    raw = pathlib.Path(path).read_bytes()
    payload = json.loads(raw)
    if payload.get("schema") != 1 or sum(payload.get("routes", {}).values()) != 100:
        raise ValueError("routing artifact schema or route weights are invalid")
    return payload, hashlib.sha256(raw).hexdigest()


def lease_agent(args):
    lock_path = pathlib.Path(args.lock)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.touch(exist_ok=True)
    stop = False

    def stopping(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    with lock_path.open("r+") as lock_handle:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("LEASE_START_FAILED reason=busy", file=sys.stderr)
            return 75
        pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
        seq = 0
        append_audit(args.audit, "lease_grant", lease_key=args.lease_key,
                     release_id=args.release_id, fencing_token=args.token, holder_pid=os.getpid())
        while not stop:
            seq += 1
            now = time.time()
            atomic_json(args.lease, {
                "lease_key": args.lease_key,
                "release_id": args.release_id,
                "fencing_token": args.token,
                "holder_pid": os.getpid(),
                "heartbeat_seq": seq,
                "renewed_at": now,
                "expires_at": now + args.ttl,
                "state": "active",
            })
            append_audit(args.audit, "lease_renew", release_id=args.release_id,
                         fencing_token=args.token, heartbeat_seq=seq, expires_at=now + args.ttl)
            deadline = time.monotonic() + args.renew_interval
            while not stop and time.monotonic() < deadline:
                time.sleep(min(0.05, deadline - time.monotonic()))
        current = load_json(args.lease, {})
        if current.get("release_id") == args.release_id and current.get("fencing_token") == args.token:
            current.update(state="released", released_at=time.time(), expires_at=time.time())
            atomic_json(args.lease, current)
            append_audit(args.audit, "lease_release", release_id=args.release_id,
                         fencing_token=args.token, heartbeat_seq=seq, owner_checked=True)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
    return 0


def edge_worker(args):
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    policy, digest = artifact(args.artifact)
    cells = [value for value in args.cells.split(",") if value]
    stop = False

    def stopping(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    sequence = 0
    while not stop:
        lease = load_json(args.lease, {})
        if (lease.get("release_id"), lease.get("fencing_token"), lease.get("state")) != (
            args.release_id, args.token, "active"
        ) or float(lease.get("expires_at", 0)) <= time.time():
            print("WORKER_EXIT reason=lease_not_owned", file=sys.stderr)
            return 4
        cell = cells[sequence % len(cells)]
        sequence += 1
        stage = "distribute" if sequence <= len(cells) else "route_probe"
        cell_state = {
            "cell": cell,
            "environment": args.environment,
            "release_id": args.release_id,
            "version": policy["release"],
            "artifact_digest": digest,
            "guardrail": policy["guardrail"],
            "routes": policy["routes"],
            "health": "passing",
            "probe": {"requests": 40 + sequence, "errors": 0, "policy_match": True},
            "updated_at": time.time(),
        }
        atomic_json(pathlib.Path(args.state_root) / "cells" / cell / "routing.json", cell_state)
        atomic_json(pathlib.Path(args.state_root) / "worker_progress.json", {
            "release_id": args.release_id,
            "fencing_token": args.token,
            "sequence": sequence,
            "stage": stage,
            "last_cell": cell,
            "artifact_digest": digest,
            "healthy": True,
            "updated_at": time.time(),
        })
        append_audit(args.audit, "worker_progress", release_id=args.release_id,
                     fencing_token=args.token, sequence=sequence, stage=stage, cell=cell,
                     artifact_digest=digest)
        time.sleep(args.step_interval)
    return 0


def acquire_with_timeout(handle, timeout):
    start = time.monotonic()
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True, int((time.monotonic() - start) * 1000)
        except BlockingIOError:
            if time.monotonic() - start >= timeout:
                return False, int((time.monotonic() - start) * 1000)
            time.sleep(0.1)


def deploy(args):
    if args.environment != "prod-edge":
        print("DEPLOY_INVALID environment", file=sys.stderr)
        return 2
    policy, digest = artifact(args.artifact)
    lock_path = pathlib.Path(args.lock)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.touch(exist_ok=True)
    cells = [value for value in args.cells.split(",") if value]
    with lock_path.open("r+") as lock_handle:
        acquired, waited_ms = acquire_with_timeout(lock_handle, args.lock_timeout)
        if not acquired:
            owner = load_json(args.lease, {})
            print(
                "DEPLOY_BUSY lease_key=%s owner=%s fencing_token=%s heartbeat_seq=%s waited_ms=%s"
                % (args.lease_key, owner.get("release_id", "unknown"),
                   owner.get("fencing_token", "unknown"), owner.get("heartbeat_seq", "unknown"), waited_ms),
                file=sys.stderr,
            )
            return 75
        token = "edge-grant-" + uuid.uuid4().hex[:16]
        started = time.time()
        atomic_json(args.lease, {
            "lease_key": args.lease_key, "release_id": args.release_id,
            "fencing_token": token, "holder_pid": os.getpid(), "heartbeat_seq": 1,
            "renewed_at": started, "expires_at": started + max(30, args.lock_timeout + 10),
            "state": "active",
        })
        append_audit(args.audit, "lease_grant", lease_key=args.lease_key,
                     release_id=args.release_id, fencing_token=token, holder_pid=os.getpid())
        for index, cell in enumerate(cells, 1):
            atomic_json(pathlib.Path(args.state_root) / "cells" / cell / "routing.json", {
                "cell": cell, "environment": args.environment, "release_id": args.release_id,
                "version": policy["release"], "artifact_digest": digest,
                "guardrail": policy["guardrail"], "routes": policy["routes"],
                "health": "passing",
                "probe": {"requests": 64 + index, "errors": 0, "policy_match": True},
                "updated_at": time.time(),
            })
            append_audit(args.audit, "cell_applied", release_id=args.release_id,
                         fencing_token=token, cell=cell, ordinal=index, artifact_digest=digest)
            time.sleep(args.cell_delay)
        active = {
            "environment": args.environment, "release_id": args.release_id,
            "version": policy["release"], "artifact_digest": digest,
            "fencing_token": token, "cells": cells, "healthy_cells": len(cells),
            "committed_at": time.time(),
        }
        atomic_json(pathlib.Path(args.state_root) / "active_release.json", active)
        append_audit(args.audit, "release_commit", release_id=args.release_id,
                     fencing_token=token, artifact_digest=digest, healthy_cells=len(cells))
        atomic_json(args.receipt, {**active, "lease_key": args.lease_key, "lease_wait_ms": waited_ms})
        lease = load_json(args.lease, {})
        lease.update(state="released", released_at=time.time(), expires_at=time.time())
        atomic_json(args.lease, lease)
        append_audit(args.audit, "lease_release", release_id=args.release_id,
                     fencing_token=token, owner_checked=True)
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
    print(f"DEPLOY_OK release_id={args.release_id} version={policy['release']} cells={len(cells)} digest={digest}")
    return 0


def show_status(args):
    lease = load_json(args.lease, {})
    progress = load_json(pathlib.Path(args.state_root) / "worker_progress.json", {})
    active = load_json(pathlib.Path(args.state_root) / "active_release.json", {})
    print(json.dumps({"lease": lease, "worker": progress, "active_release": active}, indent=2, sort_keys=True))
    return 0


def common_lease(parser):
    parser.add_argument("--lock", required=True)
    parser.add_argument("--lease", required=True)
    parser.add_argument("--audit", required=True)
    parser.add_argument("--lease-key", required=True)
    parser.add_argument("--release-id", required=True)


def main():
    ap = argparse.ArgumentParser(prog="edge-releasectl")
    sub = ap.add_subparsers(dest="command", required=True)
    lease = sub.add_parser("lease-agent")
    common_lease(lease)
    lease.add_argument("--token", required=True)
    lease.add_argument("--ttl", type=float, required=True)
    lease.add_argument("--renew-interval", type=float, required=True)
    lease.add_argument("--pid-file", required=True)
    lease.set_defaults(func=lease_agent)

    worker = sub.add_parser("routing-worker")
    worker.add_argument("--state-root", required=True)
    worker.add_argument("--lease", required=True)
    worker.add_argument("--audit", required=True)
    worker.add_argument("--environment", required=True)
    worker.add_argument("--artifact", required=True)
    worker.add_argument("--release-id", required=True)
    worker.add_argument("--token", required=True)
    worker.add_argument("--cells", required=True)
    worker.add_argument("--pid-file", required=True)
    worker.add_argument("--step-interval", type=float, default=0.55)
    worker.set_defaults(func=edge_worker)

    deploy_cmd = sub.add_parser("deploy")
    deploy_cmd.add_argument("--environment", required=True)
    deploy_cmd.add_argument("--artifact", required=True)
    deploy_cmd.add_argument("--release-id", required=True)
    deploy_cmd.add_argument("--lock-timeout", type=float, required=True)
    deploy_cmd.add_argument("--receipt", required=True)
    deploy_cmd.add_argument("--lock", default="/var/lock/edge-release/prod-edge-inference-routing.lock")
    deploy_cmd.add_argument("--lease", default="/srv/edge-release/prod-edge-inference-routing/lease.json")
    deploy_cmd.add_argument("--audit", default="/srv/edge-release/prod-edge-inference-routing/audit.jsonl")
    deploy_cmd.add_argument("--state-root", default="/srv/edge-release/prod-edge-inference-routing")
    deploy_cmd.add_argument("--lease-key", default="env/prod-edge/deployment/inference-routing")
    deploy_cmd.add_argument("--cells", default="edge-a,edge-b,edge-c,edge-d,edge-e")
    deploy_cmd.add_argument("--cell-delay", type=float, default=0.35)
    deploy_cmd.set_defaults(func=deploy)

    status = sub.add_parser("status")
    status.add_argument("--lease", default="/srv/edge-release/prod-edge-inference-routing/lease.json")
    status.add_argument("--state-root", default="/srv/edge-release/prod-edge-inference-routing")
    status.set_defaults(func=show_status)
    args = ap.parse_args()
    try:
        return int(args.func(args) or 0)
    except Exception as exc:
        print(f"{args.command.upper()}_FAILED type={type(exc).__name__} detail={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
