#!/usr/bin/python3
import argparse
import json
import os
import pathlib
import select
import signal
import time


stop = False


def on_signal(_signum, _frame):
    global stop
    stop = True


def write_state(path, value):
    target = pathlib.Path(path)
    tmp = pathlib.Path(str(target) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(target)


def make_receipt(receipt_dir, record, fifo_stat):
    record_id = str(record["record_id"])
    value = {
        "record_id": record_id,
        "producer": record.get("producer", "unknown"),
        "payload_sha256": record.get("payload_sha256", ""),
        "accepted_at": time.time(),
        "fifo_device": fifo_stat.st_dev,
        "fifo_inode": fifo_stat.st_ino,
    }
    safe = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in record_id)
    target = pathlib.Path(receipt_dir) / (safe + ".json")
    tmp = pathlib.Path(str(target) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fifo", required=True)
    parser.add_argument("--receipt-dir", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--service-ms", type=float, required=True)
    parser.add_argument("--frame-bytes", type=int, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    pathlib.Path(args.receipt_dir).mkdir(parents=True, exist_ok=True)
    fifo_stat = os.stat(args.fifo)
    fd = os.open(args.fifo, os.O_RDWR | os.O_NONBLOCK)
    state = {
        "pid": os.getpid(), "uid": os.getuid(), "running": True,
        "healthy": True, "packaged": 0, "bytes": 0, "last_error": "",
        "updated_at": time.time(), "fifo_device": fifo_stat.st_dev,
        "fifo_inode": fifo_stat.st_ino,
    }
    write_state(args.state, state)
    buffer = bytearray()
    try:
        while not stop:
            ready, _, _ = select.select([fd], [], [], 0.15)
            if not ready:
                state["updated_at"] = time.time()
                write_state(args.state, state)
                continue
            try:
                chunk = os.read(fd, args.frame_bytes * 8)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            buffer.extend(chunk)
            while len(buffer) >= args.frame_bytes:
                raw = bytes(buffer[:args.frame_bytes])
                del buffer[:args.frame_bytes]
                try:
                    line = raw.split(b"\n", 1)[0].rstrip()
                    record = json.loads(line.decode("utf-8"))
                    payload = str(record["payload"])
                    import hashlib
                    expected = hashlib.sha256(payload.encode()).hexdigest()
                    if record.get("payload_sha256") != expected:
                        raise ValueError("payload_digest_mismatch")
                    time.sleep(args.service_ms / 1000.0)
                    make_receipt(args.receipt_dir, record, fifo_stat)
                    state["packaged"] += 1
                    state["bytes"] += args.frame_bytes
                    state["updated_at"] = time.time()
                    write_state(args.state, state)
                except Exception as exc:
                    state["last_error"] = str(exc)[:160]
                    state["updated_at"] = time.time()
                    write_state(args.state, state)
    finally:
        state["running"] = False
        state["updated_at"] = time.time()
        write_state(args.state, state)
        os.close(fd)


if __name__ == "__main__":
    main()
