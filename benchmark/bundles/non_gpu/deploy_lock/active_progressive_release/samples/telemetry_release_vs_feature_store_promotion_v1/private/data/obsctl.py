#!/usr/bin/env python3
"""Lease-aware release client for the observability-prod fixture."""

import argparse
import fcntl
import json
import os
import pathlib
import signal
import sys
import time

APP = pathlib.Path("/work/observability-prod")
LEASE_DIR = APP / ".release" / "leases"
PARENT = LEASE_DIR / "observability-prod.parent.lock"
CHILDREN = {
    "telemetry-collector": LEASE_DIR / "telemetry-collector.child.lock",
    "feature-store": LEASE_DIR / "feature-store.child.lock",
}
AUDIT = APP / ".release" / "audit" / "release-client.jsonl"
COORDINATOR = APP / ".release" / "coordinator"


def now_ns():
    return time.time_ns()


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def append_event(event, **values):
    AUDIT.parent.mkdir(parents=True, exist_ok=True)
    payload = {"event": event, "pid": os.getpid(), "time_ns": now_ns(), **values}
    with AUDIT.open("a") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def lock_file(path, blocking):
    handle = pathlib.Path(path).open("a+")
    flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
    try:
        fcntl.flock(handle.fileno(), flags)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def validate_descriptor(descriptor, component=None):
    required = {"component", "version", "digest", "routing_contract", "signature"}
    if not required.issubset(descriptor):
        raise ValueError("descriptor_missing_fields")
    if component and descriptor["component"] != component:
        raise ValueError("component_mismatch")
    if descriptor["routing_contract"] != "event-schema-v3":
        raise ValueError("routing_contract_mismatch")
    if not descriptor["digest"].startswith("sha256:") or not descriptor["signature"].startswith("release-signature-"):
        raise ValueError("descriptor_verification_failed")


def deploy(args):
    if args.environment != "observability-prod":
        print(json.dumps({"result": "unsupported_environment", "environment": args.environment}))
        return 64
    descriptor = read_json(args.artifact)
    try:
        validate_descriptor(descriptor, "feature-store")
    except (ValueError, KeyError, json.JSONDecodeError) as exc:
        print(json.dumps({"result": "artifact_invalid", "detail": str(exc)}))
        return 65
    parent = lock_file(PARENT, blocking=False)
    if parent is None:
        append_event("parent_busy", environment=args.environment, component=descriptor["component"])
        print(json.dumps({
            "result": "release_busy",
            "busy_key": "observability-prod.parent.lock",
            "environment": args.environment,
            "mutation_started": False,
        }, sort_keys=True))
        return 75
    append_event("parent_acquired", environment=args.environment, component=descriptor["component"], inode=PARENT.stat().st_ino)
    child_path = CHILDREN[descriptor["component"]]
    child = lock_file(child_path, blocking=False)
    if child is None:
        append_event("child_busy", environment=args.environment, component=descriptor["component"])
        fcntl.flock(parent.fileno(), fcntl.LOCK_UN)
        parent.close()
        print(json.dumps({"result": "component_busy", "mutation_started": False}, sort_keys=True))
        return 75
    append_event("child_acquired", environment=args.environment, component=descriptor["component"], inode=child_path.stat().st_ino)
    # The overlap makes real parent+child ownership independently observable.
    time.sleep(args.hold_seconds)
    target = APP / "components" / descriptor["component"] / "current.json"
    target_payload = {
        "component": descriptor["component"],
        "version": descriptor["version"],
        "digest": descriptor["digest"],
        "routing_contract": descriptor["routing_contract"],
        "health": "passed",
        "publisher_pid": os.getpid(),
        "committed_ns": now_ns(),
    }
    atomic_json(target, target_payload)
    receipt_payload = {
        **target_payload,
        "environment": args.environment,
        "parent_lease": str(PARENT),
        "child_lease": str(child_path),
        "acquisition_order": ["environment_parent", "component_child"],
        "result": "committed",
    }
    atomic_json(args.receipt, receipt_payload)
    append_event("release_committed", environment=args.environment, component=descriptor["component"], version=descriptor["version"], digest=descriptor["digest"])
    fcntl.flock(child.fileno(), fcntl.LOCK_UN)
    fcntl.flock(parent.fileno(), fcntl.LOCK_UN)
    child.close()
    parent.close()
    print(json.dumps({"result": "release_committed", "component": descriptor["component"], "version": descriptor["version"], "receipt": args.receipt}, sort_keys=True))
    return 0


def incumbent(args):
    descriptor = read_json(args.artifact)
    validate_descriptor(descriptor, "telemetry-collector")
    parent = lock_file(PARENT, blocking=True)
    child = lock_file(CHILDREN["telemetry-collector"], blocking=True)
    release_id = args.release_id
    fencing_token = int(args.fencing_token)
    state_path = COORDINATOR / "telemetry-collector-active.json"
    pid_path = COORDINATOR / "telemetry-collector-active.pid"
    receipts = APP / "components" / "telemetry-collector" / "stage-receipts"
    nodes = APP / "components" / "telemetry-collector" / "nodes"
    receipts.mkdir(parents=True, exist_ok=True)
    nodes.mkdir(parents=True, exist_ok=True)
    running = True

    def request_stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    pid_path.write_text(f"{os.getpid()}\n")
    stages = [
        "verify_signed_artifact",
        "canary_node_1",
        "wave_nodes_2_3",
        "wave_node_4",
        "routing_contract_health",
        "post_release_query_probes",
    ]
    stage_seq = 0
    cycle = 0
    started_ns = now_ns()
    while running:
        for stage in stages:
            if not running:
                break
            stage_seq += 1
            if stage == "canary_node_1":
                selected = [1]
            elif stage == "wave_nodes_2_3":
                selected = [2, 3]
            elif stage == "wave_node_4":
                selected = [4]
            else:
                selected = []
            for node in selected:
                atomic_json(nodes / f"node-{node}.json", {
                    "node": node,
                    "component": "telemetry-collector",
                    "version": descriptor["version"],
                    "digest": descriptor["digest"],
                    "health": "passed",
                    "release_id": release_id,
                    "stage_seq": stage_seq,
                })
            receipt = {
                "release_id": release_id,
                "fencing_token": fencing_token,
                "stage": stage,
                "stage_seq": stage_seq,
                "cycle": cycle,
                "health": "passed",
                "routing_contract": descriptor["routing_contract"],
                "time_ns": now_ns(),
            }
            atomic_json(receipts / f"stage-{stage_seq:06d}.json", receipt)
            state = {
                **receipt,
                "pid": os.getpid(),
                "started_ns": started_ns,
                "component": "telemetry-collector",
                "version": descriptor["version"],
                "digest": descriptor["digest"],
                "environment": "observability-prod",
                "parent_key": "observability-prod",
                "shared_invariant": "event-schema-v3-ingest-contract",
                "parent_inode": PARENT.stat().st_ino,
                "child_inode": CHILDREN["telemetry-collector"].stat().st_ino,
                "heartbeat_ns": now_ns(),
            }
            atomic_json(state_path, state)
            append_event("incumbent_stage", release_id=release_id, fencing_token=fencing_token, stage=stage, stage_seq=stage_seq)
            time.sleep(args.stage_seconds)
        cycle += 1
    append_event("incumbent_release", release_id=release_id, fencing_token=fencing_token, stage_seq=stage_seq)
    fcntl.flock(child.fileno(), fcntl.LOCK_UN)
    fcntl.flock(parent.fileno(), fcntl.LOCK_UN)
    child.close()
    parent.close()
    return 0


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("deploy")
    p.add_argument("--environment", required=True)
    p.add_argument("--artifact", required=True)
    p.add_argument("--receipt", required=True)
    p.add_argument("--hold-seconds", type=float, default=0.8)
    p.set_defaults(func=deploy)
    p = sub.add_parser("incumbent")
    p.add_argument("--artifact", required=True)
    p.add_argument("--release-id", required=True)
    p.add_argument("--fencing-token", required=True, type=int)
    p.add_argument("--stage-seconds", type=float, default=0.28)
    p.set_defaults(func=incumbent)
    return parser


if __name__ == "__main__":
    options = build_parser().parse_args()
    try:
        raise SystemExit(options.func(options))
    except Exception as exc:
        print(json.dumps({"result": "release_error", "detail": f"{type(exc).__name__}:{exc}"}, sort_keys=True), file=sys.stderr)
        raise
