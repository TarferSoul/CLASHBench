#!/usr/bin/env python3
"""Sample Linux node health and export acknowledged FIFO batches."""
import array
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import socket
import termios
import threading
import time


fifo_path = pathlib.Path(os.environ["FIFO_PATH"])
runtime = pathlib.Path(os.environ["A_RUNTIME"])
frame_bytes = int(os.environ["FRAME_BYTES"])
records_per_flush = int(os.environ["A_BURST_RECORDS"])
buffer_interval = float(os.environ["A_BUFFER_INTERVAL_SEC"])
status_path = runtime / "status.json"
ack_path = runtime / "acks.sock"
stop_requested = False


def handle_stop(_signum, _frame):
    global stop_requested
    stop_requested = True


def atomic_json(path, value):
    snapshot = dict(value)
    snapshot["heartbeat_ns"] = time.monotonic_ns()
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(snapshot, sort_keys=True) + "\n")
    os.replace(tmp, path)
    state.clear()
    state.update(snapshot)


def read_text(path, default=""):
    try:
        return pathlib.Path(path).read_text(errors="replace").strip()
    except OSError:
        return default


def node_snapshot():
    meminfo = {}
    for line in read_text("/proc/meminfo").splitlines():
        key, _, value = line.partition(":")
        if key in {"MemTotal", "MemAvailable", "Buffers", "Cached", "SwapFree"}:
            meminfo[key] = value.strip()

    network = {"rx_bytes": 0, "tx_bytes": 0}
    for line in read_text("/proc/net/dev").splitlines()[2:]:
        _name, sep, counters = line.partition(":")
        if not sep:
            continue
        fields = counters.split()
        if len(fields) >= 9:
            network["rx_bytes"] += int(fields[0])
            network["tx_bytes"] += int(fields[8])

    process_states = {}
    process_count = 0
    for stat_path in pathlib.Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = stat_path.read_text().split()
        except OSError:
            continue
        if len(fields) > 2:
            process_count += 1
            process_states[fields[2]] = process_states.get(fields[2], 0) + 1

    snapshot = {
        "captured_unix_ns": time.time_ns(),
        "boot_id": read_text("/proc/sys/kernel/random/boot_id"),
        "loadavg": read_text("/proc/loadavg"),
        "uptime": read_text("/proc/uptime"),
        "meminfo": meminfo,
        "network": network,
        "process_count": process_count,
        "process_states": process_states,
        "cgroup_cpu": read_text("/sys/fs/cgroup/cpu.stat", "unavailable"),
        "cgroup_memory_current": read_text("/sys/fs/cgroup/memory.current", "unavailable"),
    }
    encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()
    snapshot["snapshot_sha256"] = hashlib.sha256(encoded).hexdigest()
    return snapshot


def pipe_queued(fd):
    value = array.array("i", [0])
    fcntl.ioctl(fd, termios.FIONREAD, value, True)
    return int(value[0])


def make_frame(record):
    event = dict(record)
    event["padding"] = ""
    raw = json.dumps(event, sort_keys=True, separators=(",", ":")).encode()
    padding = frame_bytes - 1 - len(raw)
    if padding < 0:
        raise RuntimeError("diagnostic snapshot exceeds fixed atomic frame")
    event["padding"] = "x" * padding
    wire = json.dumps(event, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    if len(wire) != frame_bytes:
        raise RuntimeError(f"frame construction mismatch: {len(wire)} != {frame_bytes}")
    return wire


signal.signal(signal.SIGTERM, handle_stop)
signal.signal(signal.SIGINT, handle_stop)
runtime.mkdir(parents=True, exist_ok=True)
os.chmod(runtime, 0o700)
try:
    ack_path.unlink()
except FileNotFoundError:
    pass
acks = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
acks.bind(str(ack_path))
os.chmod(ack_path, 0o600)
acks.settimeout(0.1)
received_acks = set()
ack_lock = threading.Lock()
ack_stop = threading.Event()


def receive_acknowledgements():
    while not ack_stop.is_set():
        try:
            ack = json.loads(acks.recv(4096))
        except socket.timeout:
            continue
        except OSError:
            break
        session_id = ack.get("session_id")
        record_id = ack.get("id")
        if session_id and record_id:
            with ack_lock:
                received_acks.add((session_id, record_id))


ack_thread = threading.Thread(target=receive_acknowledgements, name="diagnostics-ack-receiver", daemon=True)
ack_thread.start()
writer = os.open(fifo_path, os.O_WRONLY)
capacity = int(fcntl.fcntl(writer, getattr(fcntl, "F_GETPIPE_SZ", 1032)))
pipe_buf = int(os.pathconf(fifo_path, "PC_PIPE_BUF"))
if frame_bytes > pipe_buf:
    raise SystemExit(f"frame_bytes={frame_bytes} exceeds PIPE_BUF={pipe_buf}")

state = {
    "pid": os.getpid(),
    "phase": "starting",
    "generation": 0,
    "completed_flushes": 0,
    "last_completed_generation": 0,
    "last_completed_acknowledged": 0,
    "buffered_records": 0,
    "sent_records": 0,
    "acknowledged_records": 0,
    "blocked_ns_total": 0,
    "max_write_ns": 0,
    "pipe_capacity": capacity,
    "pipe_buf": pipe_buf,
    "occupancy_bytes": pipe_queued(writer),
}
atomic_json(status_path, state)

while not stop_requested:
    generation = state["generation"] + 1
    session_id = f"node-diag-{os.getpid()}-{generation}"
    batch = []
    state.update(
        phase="buffering",
        generation=generation,
        buffered_records=0,
        sent_records=0,
        acknowledged_records=0,
        flush_started_ns=None,
    )
    for sequence in range(1, records_per_flush + 1):
        if stop_requested:
            break
        time.sleep(buffer_interval / records_per_flush)
        batch.append(
            {
                "id": f"node-snapshot-{generation:04d}-{sequence:03d}",
                "kind": "node_diagnostic_snapshot",
                "producer": "node-diagnostics-exporter",
                "session_id": session_id,
                "sequence": sequence,
                "snapshot": node_snapshot(),
                "reply_socket": str(ack_path),
            }
        )
        state["buffered_records"] = len(batch)
        state["occupancy_bytes"] = pipe_queued(writer)
        atomic_json(status_path, state)
    if stop_requested:
        break

    state.update(phase="flushing", flush_started_ns=time.monotonic_ns(), sent_records=0, acknowledged_records=0)
    atomic_json(status_path, state)
    for record in batch:
        started_ns = time.monotonic_ns()
        while True:
            try:
                written = os.write(writer, make_frame(record))
                break
            except InterruptedError:
                if stop_requested:
                    break
        if stop_requested:
            break
        if written != frame_bytes:
            raise RuntimeError(f"partial atomic write: {written}/{frame_bytes}")
        write_ns = time.monotonic_ns() - started_ns
        state["sent_records"] += 1
        state["blocked_ns_total"] += write_ns
        state["max_write_ns"] = max(state["max_write_ns"], write_ns)
        state["occupancy_bytes"] = pipe_queued(writer)
        with ack_lock:
            state["acknowledged_records"] = sum(session == session_id for session, _record_id in received_acks)
        atomic_json(status_path, state)
    if stop_requested:
        break

    state["phase"] = "awaiting_acknowledgements"
    atomic_json(status_path, state)
    deadline = time.monotonic() + max(10.0, records_per_flush * 0.2)
    seen_count = 0
    while seen_count < len(batch) and not stop_requested:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            state["phase"] = "failed"
            state["failure"] = "acknowledgement_timeout"
            atomic_json(status_path, state)
            raise SystemExit(2)
        with ack_lock:
            seen_count = sum(session == session_id for session, _record_id in received_acks)
        state["acknowledged_records"] = seen_count
        atomic_json(status_path, state)
        if seen_count < len(batch):
            time.sleep(min(0.05, remaining))
    if stop_requested:
        break
    state["completed_flushes"] += 1
    state["last_completed_generation"] = generation
    state["last_completed_acknowledged"] = seen_count
    state["phase"] = "flush_complete"
    state["occupancy_bytes"] = pipe_queued(writer)
    atomic_json(status_path, state)

state["phase"] = "stopped"
state["occupancy_bytes"] = pipe_queued(writer)
atomic_json(status_path, state)
os.close(writer)
ack_stop.set()
ack_thread.join(timeout=0.3)
acks.close()
try:
    ack_path.unlink()
except FileNotFoundError:
    pass
