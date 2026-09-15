#!/usr/bin/env python3
"""Local FIFO collector with bounded per-record processing service."""
import array
import fcntl
import json
import os
import pathlib
import select
import signal
import socket
import stat
import termios
import time


fifo_path = pathlib.Path(os.environ["FIFO_PATH"])
runtime = pathlib.Path(os.environ["COLLECTOR_RUNTIME"])
archive_path = pathlib.Path(os.environ["COLLECTOR_ARCHIVE"])
frame_bytes = int(os.environ["FRAME_BYTES"])
target_capacity = int(os.environ["PIPE_TARGET_CAPACITY"])
service_seconds = int(os.environ["COLLECTOR_SERVICE_MS"]) / 1000.0
status_path = runtime / "status.json"
stop_requested = False


def handle_stop(_signum, _frame):
    global stop_requested
    stop_requested = True


def atomic_json(path, value):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(tmp, path)


def queued_bytes(fd):
    value = array.array("i", [0])
    fcntl.ioctl(fd, termios.FIONREAD, value, True)
    return int(value[0])


signal.signal(signal.SIGTERM, handle_stop)
signal.signal(signal.SIGINT, handle_stop)
runtime.mkdir(parents=True, exist_ok=True)
os.chmod(runtime, 0o700)
fifo_path.parent.mkdir(parents=True, exist_ok=True)
os.chmod(fifo_path.parent, 0o755)
if fifo_path.exists():
    if not stat.S_ISFIFO(fifo_path.stat().st_mode):
        raise SystemExit(f"route exists but is not a FIFO: {fifo_path}")
else:
    os.mkfifo(fifo_path, 0o666)
os.chmod(fifo_path, 0o666)
archive_path.parent.mkdir(parents=True, exist_ok=True)
os.chmod(archive_path.parent, 0o700)
archive_path.touch(exist_ok=True)
os.chmod(archive_path, 0o640)

# O_RDWR keeps the named route available between producers without consuming
# or fabricating records. Reducing an unusually large default bounds memory for
# this local control-plane collector; smaller image defaults are preserved.
fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
get_pipe_size = getattr(fcntl, "F_GETPIPE_SZ", 1032)
set_pipe_size = getattr(fcntl, "F_SETPIPE_SZ", 1031)
capacity = int(fcntl.fcntl(fd, get_pipe_size))
if capacity > target_capacity:
    capacity = int(fcntl.fcntl(fd, set_pipe_size, target_capacity))
pipe_buf = int(os.pathconf(fifo_path, "PC_PIPE_BUF"))
if frame_bytes > pipe_buf:
    raise SystemExit(f"frame_bytes={frame_bytes} exceeds PIPE_BUF={pipe_buf}")

fifo_stat = fifo_path.stat()
state = {
    "pid": os.getpid(),
    "phase": "ready",
    "accepted_total": 0,
    "accepted_diagnostics": 0,
    "accepted_alerts": 0,
    "bytes_read": 0,
    "last_id": None,
    "last_session_id": None,
    "fifo_dev": fifo_stat.st_dev,
    "fifo_ino": fifo_stat.st_ino,
    "pipe_capacity": capacity,
    "pipe_buf": pipe_buf,
    "service_ms": int(service_seconds * 1000),
}


def publish():
    state["heartbeat_ns"] = time.monotonic_ns()
    state["queued_bytes"] = queued_bytes(fd)
    atomic_json(status_path, state)


def accept_record(line):
    try:
        event = json.loads(line)
    except json.JSONDecodeError as exc:
        state["parse_errors"] = int(state.get("parse_errors", 0)) + 1
        state["last_error"] = str(exc)
        publish()
        return
    required = ("id", "producer", "session_id", "reply_socket", "sequence")
    if any(key not in event for key in required):
        state["parse_errors"] = int(state.get("parse_errors", 0)) + 1
        state["last_error"] = "missing_required_field"
        publish()
        return

    # Service time models the collector's normal enrichment and archival path.
    time.sleep(service_seconds)
    accepted_ns = time.monotonic_ns()
    durable = dict(event)
    durable.pop("padding", None)
    durable["accepted_ns"] = accepted_ns
    durable["wire_bytes"] = len(line) + 1
    with archive_path.open("a") as archive:
        archive.write(json.dumps(durable, sort_keys=True) + "\n")
        archive.flush()

    state["accepted_total"] += 1
    if event["producer"] == "node-diagnostics-exporter":
        state["accepted_diagnostics"] += 1
    elif event["producer"] == "priority-alert-client":
        state["accepted_alerts"] += 1
    state["last_id"] = event["id"]
    state["last_session_id"] = event["session_id"]
    publish()

    ack = {
        "id": event["id"],
        "sequence": event["sequence"],
        "session_id": event["session_id"],
        "accepted_ns": accepted_ns,
        "collector_pid": os.getpid(),
    }
    try:
        ack_socket.sendto(json.dumps(ack, sort_keys=True).encode(), event["reply_socket"])
    except (FileNotFoundError, ConnectionRefusedError, OSError):
        state["ack_delivery_errors"] = int(state.get("ack_delivery_errors", 0)) + 1
        publish()


ack_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
buffer = b""
publish()
while not stop_requested:
    readable, _, _ = select.select([fd], [], [], 0.1)
    if not readable:
        publish()
        continue
    chunk = os.read(fd, frame_bytes)
    if not chunk:
        publish()
        continue
    state["bytes_read"] += len(chunk)
    buffer += chunk
    while b"\n" in buffer:
        line, buffer = buffer.split(b"\n", 1)
        if line:
            accept_record(line)

state["phase"] = "stopped"
publish()
ack_socket.close()
os.close(fd)
