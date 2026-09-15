#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import struct
import sys
import time

ZERO = "0" * 64


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def payload_digest(payload):
    return hashlib.sha256(canonical(payload).encode()).hexdigest()


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


def encode_frame(body):
    body_bytes = canonical(body).encode()
    digest = hashlib.sha256(bytes.fromhex(body["previous_sha256"]) + body_bytes).digest()
    return struct.pack(">I", len(body_bytes)) + body_bytes + digest, digest.hex()


def parse_frames(path):
    data = pathlib.Path(path).read_bytes()
    frames = []
    offset = 0
    previous = ZERO
    while offset < len(data):
        start = offset
        if len(data) - offset < 4:
            raise ValueError("trailing partial frame length")
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        offset += 4
        if length < 2 or length > 1024 * 1024 or len(data) - offset < length + 32:
            raise ValueError("invalid frame length")
        body_bytes = data[offset:offset + length]
        offset += length
        digest = data[offset:offset + 32]
        offset += 32
        body = json.loads(body_bytes)
        if canonical(body).encode() != body_bytes:
            raise ValueError("non-canonical frame body")
        if body["sequence"] != len(frames) or body["previous_sha256"] != previous:
            raise ValueError("duplicate sequence or broken ancestry")
        if body["payload_sha256"] != payload_digest(body["payload"]):
            raise ValueError("payload digest mismatch")
        expected = hashlib.sha256(bytes.fromhex(previous) + body_bytes).digest()
        if digest != expected:
            raise ValueError("frame digest mismatch")
        frames.append({"body": body, "frame_sha256": digest.hex(), "start_offset": start, "end_offset": offset})
        previous = digest.hex()
    return frames


def verify_chain(journal, head_path, expect_genesis_id):
    head = json.loads(pathlib.Path(head_path).read_text())
    frames = parse_frames(journal)
    if not frames or head["sequence"] >= len(frames):
        raise ValueError("head outside journal")
    genesis = frames[0]
    if genesis["body"]["payload"].get("event_id") != expect_genesis_id or genesis["body"]["previous_sha256"] != ZERO:
        raise ValueError("trusted genesis mismatch")
    committed = frames[int(head["sequence"])]
    if committed["frame_sha256"] != head["frame_sha256"] or committed["end_offset"] != head["end_offset"]:
        raise ValueError("head digest or offset mismatch")
    stat = pathlib.Path(journal).stat()
    if (head["journal_device"], head["journal_inode"]) != (stat.st_dev, stat.st_ino):
        raise ValueError("head points to another journal inode")
    return frames, head


def append_frame(journal, head_path, payload, generation, writer):
    head = json.loads(pathlib.Path(head_path).read_text())
    body = {
        "sequence": int(head["sequence"]) + 1,
        "previous_sha256": head["frame_sha256"],
        "payload": payload,
        "payload_sha256": payload_digest(payload),
        "lease_generation": int(generation),
        "writer": writer,
        "writer_pid": os.getpid(),
        "writer_uid": os.getuid(),
        "committed_at_ns": time.time_ns(),
    }
    frame, digest = encode_frame(body)
    fd = os.open(journal, os.O_WRONLY | os.O_APPEND)
    try:
        start = os.lseek(fd, 0, os.SEEK_END)
        written = os.write(fd, frame)
        if written != len(frame):
            raise OSError("short frame write")
        os.fsync(fd)
    finally:
        os.close(fd)
    end = start + len(frame)
    stat = pathlib.Path(journal).stat()
    atomic_json(head_path, {
        "sequence": body["sequence"],
        "frame_sha256": digest,
        "end_offset": end,
        "lease_generation": int(generation),
        "journal_device": stat.st_dev,
        "journal_inode": stat.st_ino,
    })
    return body, digest, start, end, len(frame)


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
    with temp.open("w") as handle:
        handle.write(f"{value}\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, 0o664)
    os.replace(temp, path)
    fsync_directory(path.parent)
    return value


def set_lease_state(path, generation, role):
    atomic_json(path, {
        "generation": generation,
        "holder_pid": os.getpid(),
        "holder_uid": os.getuid(),
        "holder_start_ticks": pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21],
        "role": role,
    })


def cmd_init(args):
    for path in (args.journal, args.head, args.generation, args.lease, args.lease_state):
        pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.journal).write_bytes(b"")
    os.chmod(args.journal, 0o664)
    pathlib.Path(args.generation).write_text("0\n")
    os.chmod(args.generation, 0o664)
    pathlib.Path(args.lease).touch()
    os.chmod(args.lease, 0o664)
    payload = {
        "event_id": args.genesis_id,
        "event_type": "trusted_genesis",
        "journal": "privileged-command-audit",
        "created": "2026-01-01T00:00:00Z",
    }
    body = {
        "sequence": 0,
        "previous_sha256": ZERO,
        "payload": payload,
        "payload_sha256": payload_digest(payload),
        "lease_generation": 0,
        "writer": "journal-bootstrap",
        "writer_pid": 0,
        "writer_uid": 0,
        "committed_at_ns": 1767225600000000000,
    }
    frame, digest = encode_frame(body)
    with open(args.journal, "wb") as handle:
        handle.write(frame)
        handle.flush()
        os.fsync(handle.fileno())
    stat = pathlib.Path(args.journal).stat()
    atomic_json(args.head, {
        "sequence": 0,
        "frame_sha256": digest,
        "end_offset": len(frame),
        "lease_generation": 0,
        "journal_device": stat.st_dev,
        "journal_inode": stat.st_ino,
    })
    atomic_json(args.lease_state, {"generation": 0, "holder_pid": None, "holder_uid": None, "role": "unowned"})
    print(f"JOURNAL_INITIALIZED sequence=0 genesis_sha256={digest} end_offset={len(frame)}")


def cmd_make_feed(args):
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    commands = ["systemctl status model-router", "journalctl -u scheduler --since -5m", "ss -ltnp", "kubectl get pods -n training"]
    with output.open("w", encoding="utf-8") as handle:
        for index in range(args.records):
            command = commands[index % len(commands)]
            payload = {
                "event_id": f"privileged-session-{index // 12 + 1:05d}-command-{index % 12 + 1:02d}",
                "event_type": "privileged_command_completed",
                "session_id": f"ops-session-{index // 12 + 1:05d}",
                "command_sha256": hashlib.sha256(f"{command}:{index}".encode()).hexdigest(),
                "exit_code": 0,
                "policy_decision": "approved_oncall_session",
            }
            handle.write(canonical(payload) + "\n")
    print(f"TRANSCRIPT_FEED_READY records={args.records}")


def cmd_append(args):
    handle = acquire_lease(args.lease, args.timeout)
    if handle is None:
        print(f"LEASE_BUSY lease={args.lease} timeout={args.timeout}", file=sys.stderr)
        return 75
    try:
        generation = next_generation(args.generation)
        set_lease_state(args.lease_state, generation, args.writer)
        payload = json.loads(pathlib.Path(args.payload).read_text())
        body, digest, start, end, length = append_frame(args.journal, args.head, payload, generation, args.writer)
        stat = pathlib.Path(args.journal).stat()
        atomic_json(args.receipt, {
            "event_id": payload["event_id"],
            "sequence": body["sequence"],
            "frame_sha256": digest,
            "payload_sha256": body["payload_sha256"],
            "start_offset": start,
            "end_offset": end,
            "frame_length": length,
            "lease_generation": generation,
            "journal_device": stat.st_dev,
            "journal_inode": stat.st_ino,
            "durable": True,
        })
        print(f"APPEND_OK event_id={payload['event_id']} sequence={body['sequence']} end_offset={end} frame_sha256={digest}")
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
    set_lease_state(args.lease_state, generation, args.writer)
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    running = True
    def stop(_signum, _frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    durable = 0
    try:
        for line in pathlib.Path(args.input).read_text().splitlines():
            if not running:
                break
            payload = json.loads(line)
            body, digest, _start, end, _length = append_frame(args.journal, args.head, payload, generation, args.writer)
            durable += 1
            atomic_json(args.progress, {
                "pid": os.getpid(),
                "phase": "draining_transcripts",
                "lease_generation": generation,
                "durable_frames": durable,
                "last_sequence": body["sequence"],
                "last_end_offset": end,
                "last_frame_sha256": digest,
            })
            time.sleep(args.delay)
        return 0
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def cmd_verify(args):
    frames, head = verify_chain(args.journal, args.head, args.expect_genesis_id)
    print(f"CHAIN_OK=1 frames={len(frames)} committed_sequence={head['sequence']} end_offset={head['end_offset']} head_sha256={head['frame_sha256']}")


def parser():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    for name in ("journal", "head", "generation", "lease", "lease_state", "genesis_id"):
        init.add_argument(f"--{name.replace('_', '-')}", required=True)
    init.set_defaults(func=cmd_init)
    feed = sub.add_parser("make-feed")
    feed.add_argument("--output", required=True)
    feed.add_argument("--records", type=int, required=True)
    feed.set_defaults(func=cmd_make_feed)
    append = sub.add_parser("append")
    for name in ("journal", "head", "generation", "lease", "lease_state", "writer", "payload", "receipt"):
        append.add_argument(f"--{name.replace('_', '-')}", required=True)
    append.add_argument("--timeout", type=float, default=3)
    append.set_defaults(func=cmd_append)
    sequencer = sub.add_parser("sequencer")
    for name in ("journal", "head", "generation", "lease", "lease_state", "writer", "input", "progress", "pid_file"):
        sequencer.add_argument(f"--{name.replace('_', '-')}", required=True)
    sequencer.add_argument("--timeout", type=float, default=3)
    sequencer.add_argument("--delay", type=float, required=True)
    sequencer.set_defaults(func=cmd_sequencer)
    verify = sub.add_parser("verify")
    verify.add_argument("--journal", required=True)
    verify.add_argument("--head", required=True)
    verify.add_argument("--expect-genesis-id", required=True)
    verify.set_defaults(func=cmd_verify)
    return ap


if __name__ == "__main__":
    arguments = parser().parse_args()
    raise SystemExit(arguments.func(arguments) or 0)
