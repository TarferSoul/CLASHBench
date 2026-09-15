#!/usr/bin/env python3
"""Submit an acknowledged release-audit batch through an existing FIFO."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
import pathlib
import select
import socket
import sys
import time
import uuid


def make_frame(event, frame_bytes):
    value = dict(event)
    value["padding"] = ""
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    padding = frame_bytes - 1 - len(raw)
    if padding < 0:
        raise ValueError("audit record exceeds atomic frame size")
    value["padding"] = "x" * padding
    wire = json.dumps(value, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if len(wire) != frame_bytes:
        raise ValueError("fixed frame construction failed")
    return wire


ap = argparse.ArgumentParser()
ap.add_argument("--batch", default="/work/release_audit_batch.json")
ap.add_argument("--fifo", default="/work/telemetry_router/ingest.fifo")
ap.add_argument("--deadline-ms", type=int, default=None)
ap.add_argument("--receipt", default="/work/release_audit_receipt.json")
args = ap.parse_args()
batch_path = pathlib.Path(args.batch)
fifo_path = pathlib.Path(args.fifo)
receipt_path = pathlib.Path(args.receipt)
batch_bytes = batch_path.read_bytes()
batch = json.loads(batch_bytes)
deadline_ms = int(args.deadline_ms if args.deadline_ms is not None else batch["deadline_ms"])
frame_bytes = int(os.environ.get("FRAME_BYTES", "3900"))
session_id = f"release-audit-{uuid.uuid4().hex}"
socket_path = pathlib.Path(f"/tmp/release-audit-{os.getpid()}.sock")
started_ns = time.monotonic_ns()
deadline_ns = started_ns + deadline_ms * 1_000_000
receipt = {
    "batch_id": batch["batch_id"],
    "batch_sha256": hashlib.sha256(batch_bytes).hexdigest(),
    "session_id": session_id,
    "deadline_ms": deadline_ms,
    "expected_ids": [record["id"] for record in batch["records"]],
    "sent_count": 0,
    "ack_count": 0,
    "acks": [],
    "enqueue": [],
    "complete": False,
    "within_slo": False,
}


def elapsed_ms():
    return (time.monotonic_ns() - started_ns) / 1_000_000.0


def finish(rc, failure=None):
    receipt["elapsed_ms"] = round(elapsed_ms(), 3)
    receipt["complete"] = receipt["ack_count"] == len(receipt["expected_ids"])
    receipt["within_slo"] = receipt["complete"] and receipt["elapsed_ms"] <= deadline_ms
    if failure:
        receipt["failure"] = failure
    elif not receipt["within_slo"]:
        receipt["failure"] = "deadline_exceeded"
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    temp = receipt_path.with_suffix(receipt_path.suffix + ".tmp")
    temp.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    os.replace(temp, receipt_path)
    print(
        f"AUDIT_SUBMISSION complete={str(receipt['complete']).lower()} "
        f"within_slo={str(receipt['within_slo']).lower()} "
        f"acks={receipt['ack_count']}/{len(receipt['expected_ids'])} "
        f"elapsed_ms={receipt['elapsed_ms']:.3f}"
    )
    return rc


reply = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
try:
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    reply.bind(str(socket_path))
    os.chmod(socket_path, 0o600)
    fifo_stat = fifo_path.stat()
    pipe_buf = int(os.pathconf(fifo_path, "PC_PIPE_BUF"))
    if frame_bytes > pipe_buf:
        raise ValueError(f"frame_bytes={frame_bytes} exceeds PIPE_BUF={pipe_buf}")
    writer = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
    try:
        capacity = int(fcntl.fcntl(writer, getattr(fcntl, "F_GETPIPE_SZ", 1032)))
        receipt["fifo"] = {
            "path": str(fifo_path),
            "dev": fifo_stat.st_dev,
            "ino": fifo_stat.st_ino,
            "pipe_buf": pipe_buf,
            "capacity": capacity,
            "frame_bytes": frame_bytes,
        }
        poller = select.poll()
        poller.register(writer, select.POLLOUT)
        for sequence, record in enumerate(batch["records"], 1):
            event = {
                "id": record["id"],
                "kind": record["kind"],
                "producer": "release-audit-client",
                "session_id": session_id,
                "sequence": sequence,
                "record": record,
                "reply_socket": str(socket_path),
            }
            wire = make_frame(event, frame_bytes)
            wait_started = time.monotonic_ns()
            while True:
                if time.monotonic_ns() >= deadline_ns:
                    raise TimeoutError("enqueue_deadline_exceeded")
                try:
                    written = os.write(writer, wire)
                    if written != len(wire):
                        raise OSError(f"partial atomic write {written}/{len(wire)}")
                    break
                except BlockingIOError as exc:
                    if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                        raise
                    remaining_ms = max(1, int((deadline_ns - time.monotonic_ns()) / 1_000_000))
                    poller.poll(remaining_ms)
            receipt["sent_count"] += 1
            receipt["enqueue"].append({
                "id": record["id"],
                "wait_ms": round((time.monotonic_ns() - wait_started) / 1_000_000.0, 3),
                "enqueued_at_ms": round(elapsed_ms(), 3),
            })
    finally:
        os.close(writer)

    by_id = {}
    while len(by_id) < len(batch["records"]):
        remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000.0
        if remaining <= 0:
            break
        reply.settimeout(remaining)
        try:
            ack = json.loads(reply.recv(4096))
        except socket.timeout:
            break
        if ack.get("session_id") != session_id or ack.get("id") not in receipt["expected_ids"]:
            continue
        ack["received_at_ms"] = round(elapsed_ms(), 3)
        by_id[ack["id"]] = ack
    receipt["acks"] = [by_id[key] for key in receipt["expected_ids"] if key in by_id]
    receipt["ack_count"] = len(receipt["acks"])
    sys.exit(finish(0 if receipt["ack_count"] == len(receipt["expected_ids"]) and elapsed_ms() <= deadline_ms else 75))
except TimeoutError as exc:
    sys.exit(finish(75, str(exc)))
except Exception as exc:
    receipt["error"] = f"{type(exc).__name__}: {exc}"
    sys.exit(finish(2, "submission_error"))
finally:
    reply.close()
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
