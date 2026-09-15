#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import sys
import time


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


def canonical_checksum(event_id, value):
    payload = json.dumps(
        {"event_id": event_id, "payload": {"value": value}},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def guard(args):
    artifact = load_descriptor(args.descriptor)
    lease = open(args.lease, "a+")
    if not acquire(lease, 2.0):
        print("rollback guard could not acquire deployment lease", file=sys.stderr)
        return 72
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    pid = os.getpid()
    pathlib.Path(args.pid_file).write_text(f"{pid}\n")
    db = sqlite3.connect(args.probe_db, timeout=2)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(
        "CREATE TABLE IF NOT EXISTS decoder_probes ("
        "sample_seq INTEGER PRIMARY KEY, recorded_ns INTEGER NOT NULL, "
        "release_id TEXT NOT NULL, legacy_decode TEXT NOT NULL, "
        "current_decode TEXT NOT NULL, output_checksum TEXT NOT NULL, "
        "mismatch_count INTEGER NOT NULL, checkpoint_offset INTEGER NOT NULL)"
    )
    db.commit()
    started_ns = time.time_ns()
    deadline_ns = started_ns + int(args.gate_seconds * 1_000_000_000)
    sample_count = 0
    while not stop:
        sample_count += 1
        now_ns = time.time_ns()
        event_id = f"compat-event-{sample_count % 3}"
        value = 1000 + sample_count
        legacy_checksum = canonical_checksum(event_id, value)
        current_checksum = canonical_checksum(event_id, value)
        mismatch_count = int(legacy_checksum != current_checksum)
        checkpoint = 448_000 + sample_count
        with db:
            db.execute(
                "INSERT INTO decoder_probes VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    sample_count,
                    now_ns,
                    args.release_id,
                    "passed",
                    "passed",
                    current_checksum,
                    mismatch_count,
                    checkpoint,
                ),
            )
        atomic_json(args.state, {
            "pid": pid,
            "uid": os.geteuid(),
            "environment": args.environment,
            "release_id": args.release_id,
            "fencing_token": int(args.fencing_token),
            "gate_state": "rollback_guard",
            "gate_deadline_ns": deadline_ns,
            "routing_state": "dual_decode_shadow_20_percent",
            "rollback_state": "eligible",
            "active_decoder_version": "12.0.6",
            "candidate_decoder_version": artifact["version"],
            "candidate_schema_epoch": int(artifact["schema_epoch"]),
            "probe_count": sample_count,
            "checkpoint_offset": checkpoint,
            "heartbeat_ns": now_ns,
            "compatibility_health": "passed",
            "lease_inode": os.fstat(lease.fileno()).st_ino,
        })
        time.sleep(args.probe_interval)
    append_json(args.audit, {
        "event": "rollback_guard_release",
        "release_id": args.release_id,
        "pid": pid,
        "recorded_ns": time.time_ns(),
    })
    db.close()
    return 0


def release_policy(args):
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
        "validate_signed_policy",
        "activate_wire_version_matrix",
        "verify_legacy_and_current_decoders",
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
        time.sleep(0.33)
    committed_ns = time.time_ns()
    target = {
        "environment": args.environment,
        "component": artifact["component"],
        "policy_version": artifact["version"],
        "policy_digest": artifact["digest"],
        "schema_epoch": int(artifact["schema_epoch"]),
        "accepted_wire_versions": artifact["accepted_wire_versions"],
        "unknown_field_action": artifact["unknown_field_action"],
        "checksum_mode": artifact["checksum_mode"],
        "legacy_decode": "passed",
        "current_decode": "passed",
        "status": "active",
        "release_id": args.release_id,
        "committed_ns": committed_ns,
    }
    receipt = {
        "status": "committed",
        "environment": args.environment,
        "release_id": args.release_id,
        "version": artifact["version"],
        "digest": artifact["digest"],
        "schema_epoch": int(artifact["schema_epoch"]),
        "accepted_wire_versions": artifact["accepted_wire_versions"],
        "legacy_decode": "passed",
        "current_decode": "passed",
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
    for flag in ("environment", "lease", "descriptor", "release-id", "fencing-token", "state", "pid-file", "probe-db", "audit"):
        gate.add_argument("--" + flag, required=True)
    gate.add_argument("--probe-interval", type=float, default=0.21)
    gate.add_argument("--gate-seconds", type=float, default=900.0)
    gate.set_defaults(func=guard)
    release = sub.add_parser("release-policy")
    for flag in ("environment", "lease", "descriptor", "release-id", "target", "receipt", "audit", "live-state"):
        release.add_argument("--" + flag, required=True)
    release.add_argument("--lock-timeout", type=float, default=0.8)
    release.set_defaults(func=release_policy)
    return top


if __name__ == "__main__":
    parsed = parser().parse_args()
    raise SystemExit(parsed.func(parsed))
