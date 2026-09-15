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

ZERO = "0" * 64


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def payload_digest(payload):
    return hashlib.sha256(canonical(payload).encode()).hexdigest()


def record_digest(core):
    return hashlib.sha256(canonical(core).encode()).hexdigest()


def fsync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value, mode=0o664):
    path = pathlib.Path(path)
    temp = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, mode)
    os.replace(temp, path)
    fsync_directory(path.parent)


def append_record(ledger, head_path, payload, generation, writer):
    ledger = pathlib.Path(ledger)
    head_path = pathlib.Path(head_path)
    head = json.loads(head_path.read_text())
    position = int(head["position"]) + 1
    core = {
        "position": position,
        "previous_sha256": head["record_sha256"],
        "payload": payload,
        "payload_sha256": payload_digest(payload),
        "lease_generation": int(generation),
        "writer": writer,
        "writer_pid": os.getpid(),
        "writer_uid": os.getuid(),
        "committed_at_ns": time.time_ns(),
    }
    digest = record_digest(core)
    record = {**core, "record_sha256": digest}
    encoded = (canonical(record) + "\n").encode()
    fd = os.open(ledger, os.O_WRONLY | os.O_APPEND)
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    atomic_json(head_path, {
        "position": position,
        "record_sha256": digest,
        "lease_generation": int(generation),
        "ledger_device": ledger.stat().st_dev,
        "ledger_inode": ledger.stat().st_ino,
    })
    return record


def verify_chain(ledger_path, head_path, expect_genesis_id):
    ledger_path = pathlib.Path(ledger_path)
    head = json.loads(pathlib.Path(head_path).read_text())
    records = [json.loads(line) for line in ledger_path.read_text().splitlines() if line.strip()]
    if not records or head["position"] >= len(records):
        raise ValueError("head outside ledger")
    previous = ZERO
    seen = set()
    for index, record in enumerate(records):
        core = {key: value for key, value in record.items() if key != "record_sha256"}
        if record["position"] != index or index in seen:
            raise ValueError("non-monotonic or duplicate position")
        if record["previous_sha256"] != previous:
            raise ValueError("broken ancestry")
        if record["payload_sha256"] != payload_digest(record["payload"]):
            raise ValueError("payload digest mismatch")
        if record["record_sha256"] != record_digest(core):
            raise ValueError("record digest mismatch")
        seen.add(index)
        previous = record["record_sha256"]
    genesis = records[0]
    if genesis["payload"].get("event_id") != expect_genesis_id or genesis["previous_sha256"] != ZERO:
        raise ValueError("trusted genesis mismatch")
    committed = records[int(head["position"])]
    if committed["record_sha256"] != head["record_sha256"]:
        raise ValueError("head digest mismatch")
    stat = ledger_path.stat()
    if (head["ledger_device"], head["ledger_inode"]) != (stat.st_dev, stat.st_ino):
        raise ValueError("head points to different ledger inode")
    return records, head


def acquire_lease(path, timeout):
    handle = open(path, "a+", encoding="utf-8")
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                return None
            time.sleep(0.05)


def next_generation(path):
    path = pathlib.Path(path)
    value = int(path.read_text().strip() or "0") + 1
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        handle.write(f"{value}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, 0o664)
    os.replace(temp, path)
    fsync_directory(path.parent)
    return value


def lease_state(path, generation, role):
    atomic_json(path, {
        "generation": generation,
        "holder_pid": os.getpid(),
        "holder_uid": os.getuid(),
        "holder_start_ticks": pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21],
        "role": role,
    })


def cmd_init(args):
    for path in (args.ledger, args.head, args.generation, args.lease, args.lease_state):
        pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.ledger).write_text("")
    os.chmod(args.ledger, 0o664)
    pathlib.Path(args.generation).write_text("0\n")
    os.chmod(args.generation, 0o664)
    pathlib.Path(args.lease).touch()
    os.chmod(args.lease, 0o664)
    genesis_payload = {
        "event_id": args.genesis_id,
        "event_type": "trusted_genesis",
        "ledger": "artifact-release-transparency",
        "created": "2026-01-01T00:00:00Z",
    }
    core = {
        "position": 0,
        "previous_sha256": ZERO,
        "payload": genesis_payload,
        "payload_sha256": payload_digest(genesis_payload),
        "lease_generation": 0,
        "writer": "ledger-bootstrap",
        "writer_pid": 0,
        "writer_uid": 0,
        "committed_at_ns": 1767225600000000000,
    }
    record = {**core, "record_sha256": record_digest(core)}
    with open(args.ledger, "w", encoding="utf-8") as handle:
        handle.write(canonical(record) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    atomic_json(args.head, {
        "position": 0,
        "record_sha256": record["record_sha256"],
        "lease_generation": 0,
        "ledger_device": pathlib.Path(args.ledger).stat().st_dev,
        "ledger_inode": pathlib.Path(args.ledger).stat().st_ino,
    })
    atomic_json(args.lease_state, {"generation": 0, "holder_pid": None, "holder_uid": None, "role": "unowned"})
    print(f"LEDGER_INITIALIZED position=0 genesis_sha256={record['record_sha256']}")


def cmd_make_feed(args):
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        for index in range(args.records):
            payload = {
                "event_id": f"release-attestation-{index + 1:06d}",
                "event_type": "release_attestation_verified",
                "repository": ["runtime/base-images", "serving/gateway", "training/pipelines"][index % 3],
                "artifact_digest": hashlib.sha256(f"artifact-{index + 1}".encode()).hexdigest(),
                "policy": "slsa-level-3",
            }
            handle.write(canonical(payload) + "\n")
    print(f"FEED_READY records={args.records} output={output}")


def cmd_append(args):
    handle = acquire_lease(args.lease, args.timeout)
    if handle is None:
        print(f"LEASE_BUSY lease={args.lease} timeout={args.timeout}", file=sys.stderr)
        return 75
    try:
        generation = next_generation(args.generation)
        lease_state(args.lease_state, generation, args.writer)
        payload = json.loads(pathlib.Path(args.payload).read_text())
        record = append_record(args.ledger, args.head, payload, generation, args.writer)
        stat = pathlib.Path(args.ledger).stat()
        receipt = {
            "event_id": payload["event_id"],
            "position": record["position"],
            "record_sha256": record["record_sha256"],
            "payload_sha256": record["payload_sha256"],
            "lease_generation": generation,
            "ledger_device": stat.st_dev,
            "ledger_inode": stat.st_ino,
            "durable": True,
        }
        atomic_json(args.receipt, receipt)
        print(f"APPEND_OK event_id={payload['event_id']} position={record['position']} generation={generation} receipt={args.receipt}")
        return 0
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def cmd_sequencer(args):
    handle = acquire_lease(args.lease, args.timeout)
    if handle is None:
        print("SEQUENCER_LEASE_BUSY", file=sys.stderr)
        return 75
    generation = next_generation(args.generation)
    lease_state(args.lease_state, generation, args.writer)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    running = True
    def stop(_signum, _frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    accepted = 0
    try:
        for line in pathlib.Path(args.input).read_text().splitlines():
            if not running:
                break
            payload = json.loads(line)
            record = append_record(args.ledger, args.head, payload, generation, args.writer)
            accepted += 1
            atomic_json(args.progress, {
                "pid": os.getpid(),
                "phase": "streaming",
                "lease_generation": generation,
                "accepted_events": accepted,
                "last_position": record["position"],
                "last_event_id": payload["event_id"],
            })
            time.sleep(args.delay)
        return 0
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def cmd_verify(args):
    records, head = verify_chain(args.ledger, args.head, args.expect_genesis_id)
    print(f"CHAIN_OK=1 records={len(records)} committed_position={head['position']} head_sha256={head['record_sha256']}")


def parser():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    for name in ("ledger", "head", "generation", "lease", "lease_state", "genesis_id"):
        init.add_argument(f"--{name.replace('_', '-')}", required=True)
    init.set_defaults(func=cmd_init)
    feed = sub.add_parser("make-feed")
    feed.add_argument("--output", required=True)
    feed.add_argument("--records", type=int, required=True)
    feed.set_defaults(func=cmd_make_feed)
    append = sub.add_parser("append")
    for name in ("ledger", "head", "generation", "lease", "lease_state", "writer", "payload", "receipt"):
        append.add_argument(f"--{name.replace('_', '-')}", required=True)
    append.add_argument("--timeout", type=float, default=3)
    append.set_defaults(func=cmd_append)
    sequencer = sub.add_parser("sequencer")
    for name in ("ledger", "head", "generation", "lease", "lease_state", "writer", "input", "progress", "pid_file"):
        sequencer.add_argument(f"--{name.replace('_', '-')}", required=True)
    sequencer.add_argument("--timeout", type=float, default=3)
    sequencer.add_argument("--delay", type=float, required=True)
    sequencer.set_defaults(func=cmd_sequencer)
    verify = sub.add_parser("verify")
    verify.add_argument("--ledger", required=True)
    verify.add_argument("--head", required=True)
    verify.add_argument("--expect-genesis-id", required=True)
    verify.set_defaults(func=cmd_verify)
    return ap


if __name__ == "__main__":
    arguments = parser().parse_args()
    raise SystemExit(arguments.func(arguments) or 0)
